#!/usr/bin/env bash
# Copy the RHCOS VHD into the cluster storage account (rhcos container)
# via the uploader VM (the storage account is PE-only; WSL cannot reach it).
# The VM streams + gunzips the .vhd.gz and uploads as a page blob.
# Architecture (x86_64 / arm64) is taken from config/cluster.env via fetch-rhcos.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source config/cluster.env so CLUSTER_SUBSCRIPTION_ID and friends are
# available without the caller having to `set -a; source ...` first.
if [[ -f "$REPO_ROOT/config/cluster.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$REPO_ROOT/config/cluster.env"
  set +a
fi

cd "$REPO_ROOT/terraform/00-prereqs"
SA_NAME=$(terraform output -raw storage_account_name)
CONTAINER=$(terraform output -raw rhcos_container_name)

cd "$REPO_ROOT/terraform/01-network"
VM_NAME=$(terraform output -raw uploader_vm_name)
VM_RG=$(terraform output -raw uploader_resource_group)

SUB="${CLUSTER_SUBSCRIPTION_ID:?set CLUSTER_SUBSCRIPTION_ID to the Azure subscription ID that contains the uploader VM}"

SRC_URL=$("$REPO_ROOT/scripts/fetch-rhcos.sh")
[[ -n "$SRC_URL" && "$SRC_URL" != "null" ]] || { echo "Failed to resolve RHCOS VHD URL"; exit 1; }

DST_BLOB="rhcos-$(basename "${SRC_URL%.gz}")"
echo "Source:      $SRC_URL"
echo "Destination: $SA_NAME / $CONTAINER / $DST_BLOB"
echo "Via VM:      $VM_NAME (rg $VM_RG)"

INNER_SCRIPT=$(cat <<EOS
set -euo pipefail
export HOME=/root
SA='${SA_NAME}'
CONT='${CONTAINER}'
DST='${DST_BLOB}'
SRC='${SRC_URL}'
WORK=/var/tmp/rhcos-upload
mkdir -p "\$WORK"
az login --identity --allow-no-subscriptions --only-show-errors >/dev/null
if az storage blob show --account-name "\$SA" --container-name "\$CONT" --name "\$DST" --auth-mode login -o none 2>/dev/null; then
  echo "BLOB_ALREADY_PRESENT=\$DST"
  echo "UPLOAD_DONE=OK"
  exit 0
fi
VHD="\$WORK/\$DST"
if [[ ! -s "\$VHD" ]]; then
  echo "Downloading + decompressing..."
  curl -fL --retry 3 --retry-delay 5 "\$SRC" | gunzip -c > "\$VHD"
fi
SZ=\$(stat -c%s "\$VHD")
echo "Uncompressed size: \$SZ bytes"
echo "Uploading as page blob..."
az storage blob upload \
  --account-name "\$SA" \
  --container-name "\$CONT" \
  --name "\$DST" \
  --file "\$VHD" \
  --type page \
  --auth-mode login \
  --overwrite \
  --only-show-errors >/dev/null
rm -f "\$VHD"
echo "UPLOAD_DONE=OK"
EOS
)
INNER_B64=$(printf '%s' "$INNER_SCRIPT" | base64 -w0)
REMOTE_SCRIPT="echo ${INNER_B64} | base64 -d | bash"

echo "Running on uploader VM (this will take several minutes)..."
OUT=$(az vm run-command invoke \
  --subscription "$SUB" \
  -g "$VM_RG" -n "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "$REMOTE_SCRIPT" \
  --query 'value[0].message' -o tsv)

echo "$OUT"
echo "$OUT" | grep -q 'UPLOAD_DONE=OK' || { echo "Upload failed."; exit 1; }

BLOB_URL="https://${SA_NAME}.blob.core.windows.net/${CONTAINER}/${DST_BLOB}"
echo "RHCOS_BLOB_URL=$BLOB_URL"

cat > "$REPO_ROOT/terraform/02-image/rhcos.auto.tfvars" <<EOF
rhcos_vhd_url = "$BLOB_URL"
EOF
echo "Wrote terraform/02-image/rhcos.auto.tfvars"
