#!/usr/bin/env bash
# Upload install/bootstrap.ign to the ignition container via the uploader VM
# (storage is PE-only). Emits pointer-ignition tfvars for stage 03.
# Chunks base64 of the ignition over multiple `az vm run-command invoke`
# calls because a single run-command script is capped near 256 KB.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="$REPO_ROOT/install"
BOOTSTRAP_IGN="$INSTALL_DIR/bootstrap.ign"

# Source config/cluster.env so CLUSTER_SUBSCRIPTION_ID and friends are
# available without the caller having to `set -a; source ...` first.
if [[ -f "$REPO_ROOT/config/cluster.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$REPO_ROOT/config/cluster.env"
  set +a
fi

[[ -f "$BOOTSTRAP_IGN" ]] || { echo "missing $BOOTSTRAP_IGN (run: make ignition)"; exit 1; }

cd "$REPO_ROOT/terraform/00-prereqs"
SA_NAME=$(terraform output -raw storage_account_name)
CONTAINER=$(terraform output -raw ignition_container_name)

cd "$REPO_ROOT/terraform/01-network"
VM_NAME=$(terraform output -raw uploader_vm_name)
VM_RG=$(terraform output -raw uploader_resource_group)

SUB="${CLUSTER_SUBSCRIPTION_ID:?set CLUSTER_SUBSCRIPTION_ID to the Azure subscription ID that contains the uploader VM}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

B64_FILE="$WORK/ign.b64"
base64 -w0 "$BOOTSTRAP_IGN" > "$B64_FILE"
# split into ~80KB chunks so each run-command POST stays well under 256 KB
split -b 80000 "$B64_FILE" "$WORK/chunk."
CHUNKS=( "$WORK"/chunk.* )
echo "Ignition is $(wc -c <"$BOOTSTRAP_IGN") bytes; uploading in ${#CHUNKS[@]} chunks via $VM_NAME..."

run_remote() {
  local script="$1"
  local f
  f=$(mktemp)
  printf '%s' "$script" > "$f"
  az vm run-command invoke \
    --subscription "$SUB" \
    -g "$VM_RG" -n "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "@$f" \
    --query 'value[0].message' -o tsv
  rm -f "$f"
}

# chunk 0: truncate destination
FIRST=1
for C in "${CHUNKS[@]}"; do
  DATA=$(cat "$C")
  if [[ $FIRST -eq 1 ]]; then
    OP='>'
    FIRST=0
  else
    OP='>>'
  fi
  OUT=$(run_remote "printf '%s' '${DATA}' ${OP} /tmp/bootstrap.ign.b64")
  echo "  chunk ok ($(wc -c <"$C") chars)"
done

# finalise: decode + upload + SAS
EXPIRY=$(date -u -d '+6 hour' '+%Y-%m-%dT%H:%MZ')
FINAL=$(cat <<EOS
exec bash <<'BASH_INNER'
set -euo pipefail
export HOME=/root
SA='${SA_NAME}'
CONT='${CONTAINER}'
EXPIRY='${EXPIRY}'
base64 -d /tmp/bootstrap.ign.b64 > /tmp/bootstrap.ign
rm -f /tmp/bootstrap.ign.b64
az login --identity --allow-no-subscriptions --only-show-errors >/dev/null
# Keep each az invocation on a single line: the storage account has
# shared_access_key_enabled=false, so if --auth-mode login / --as-user are ever
# dropped (e.g. a broken \\ line-continuation) az falls back to the account-key
# path and fails with "Authorization with Shared Key is disabled".
az storage blob upload --account-name "\$SA" --container-name "\$CONT" --name bootstrap.ign --file /tmp/bootstrap.ign --auth-mode login --overwrite --only-show-errors >/dev/null
SAS=\$(az storage blob generate-sas --account-name "\$SA" --container-name "\$CONT" --name bootstrap.ign --permissions r --expiry "\$EXPIRY" --https-only --auth-mode login --as-user -o tsv --only-show-errors)
echo "SAS_BEGIN"; echo "\$SAS"; echo "SAS_END"
BASH_INNER
EOS
)

OUT=$(run_remote "$FINAL")
SAS=$(echo "$OUT" | tr -d '\r' | awk '/SAS_BEGIN/{f=1;next}/SAS_END/{f=0}f' | tr -d '[:space:]')
[[ -n "$SAS" ]] || { echo "Failed to obtain SAS. Output was:"; echo "$OUT"; exit 1; }

BLOB_URL="https://${SA_NAME}.blob.core.windows.net/${CONTAINER}/bootstrap.ign?${SAS}"

POINTER=$(jq -n --arg url "$BLOB_URL" '{ignition:{version:"3.2.0",config:{replace:{source:$url}}}}')

cat > "$REPO_ROOT/terraform/03-bootstrap/bootstrap-ignition.auto.tfvars.json" <<EOF
{
  "bootstrap_ignition_pointer": $(echo "$POINTER" | jq -Rs .)
}
EOF

echo "Wrote terraform/03-bootstrap/bootstrap-ignition.auto.tfvars.json (SAS expires $EXPIRY)"
