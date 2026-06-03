#!/usr/bin/env bash
# Take an etcd backup from a Ready control plane node and copy it locally.
#
# Backups are written to:
#   $BACKUP_DIR/<UTC-timestamp>-<CLUSTER_NAME>/
#     ├── snapshot_<timestamp>_<node>.db
#     ├── static_kuberesources_<timestamp>_<node>.tar.gz
#     └── metadata.json
#
# Wraps the in-cluster /usr/local/bin/cluster-backup.sh script that ships
# with the OpenShift control plane image. Required by the Red Hat
# graceful-shutdown procedure:
#   https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/backup_and_restore/graceful-shutdown-cluster
#
# Usage:
#   scripts/cluster-etcd-backup.sh [--node <name>] [--out <dir>] [--dry-run]
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

NODE=""
OUT_OVERRIDE=""

while (( $# > 0 )); do
  case "$1" in
    --node)   NODE=$(flag_value "--node" "${2:-}"); shift 2 ;;
    --out)    OUT_OVERRIDE=$(flag_value "--out" "${2:-}"); shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,16p' "$0"; exit 0 ;;
    *)
      log_err "unknown flag: $1"; exit 2 ;;
  esac
done

load_config
require_oc
require_cmd jq tar base64 awk gzip

# Pick a Ready master if the caller did not specify one.
if [[ -z "$NODE" ]]; then
  NODE=$(oc get nodes -l node-role.kubernetes.io/master -o json \
    | jq -r '.items[]
        | select((.status.conditions // [])[] | select(.type=="Ready" and .status=="True"))
        | .metadata.name' \
    | head -n1)
fi
if [[ -z "$NODE" ]]; then
  log_err "no Ready control plane node found; cannot take etcd backup"
  exit 1
fi
log_info "etcd backup will run on node: $NODE"

TS=$(date -u +"%Y%m%dT%H%M%SZ")
DEST="${OUT_OVERRIDE:-$REPO_ROOT/$BACKUP_DIR/${TS}-${CLUSTER_NAME}}"
log_info "local destination: $DEST"

if [[ "$DRY_RUN" == "1" ]]; then
  log_info "[dry-run] would create $DEST and run cluster-backup.sh on $NODE"
  exit 0
fi

mkdir -p "$DEST"

CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
SERVER=$(oc whoami --show-server 2>/dev/null || echo "unknown")
EXPIRY=$(cert_expiry || echo "")

log_step "running /usr/local/bin/cluster-backup.sh on $NODE"
REMOTE_OUT_DIR="/var/home/core/backup-${TS}"
# Important: oc debug and backup helper processes can emit informational text
# to stdout. Delimit the payload explicitly; do not rely on "base64-looking"
# line filtering because ordinary log text can accidentally match that shape.
oc debug "node/${NODE}" --quiet --to-namespace=default -- chroot /host bash -c "
  set -euo pipefail
  rm -rf '${REMOTE_OUT_DIR}' >&2
  mkdir -p '${REMOTE_OUT_DIR}' >&2
  /usr/local/bin/cluster-backup.sh '${REMOTE_OUT_DIR}' >&2
  cd '${REMOTE_OUT_DIR}'
  tar -czf /tmp/etcd-backup-${TS}.tar.gz . >&2
  echo __OCP_ETCD_BACKUP_BEGIN__
  base64 -w0 < /tmp/etcd-backup-${TS}.tar.gz
  echo
  echo __OCP_ETCD_BACKUP_END__
  rm -f /tmp/etcd-backup-${TS}.tar.gz >&2
" | awk '
  { sub(/\r$/, "") }
  /^__OCP_ETCD_BACKUP_BEGIN__$/ {
    if (!found && !capture) {
      capture = 1
      payload = ""
    }
    next
  }
  /^__OCP_ETCD_BACKUP_END__$/ {
    if (capture && !found) {
      found = 1
      capture = 0
    }
    next
  }
  capture && !found { payload = payload $0 }
  END {
    if (found && payload != "") {
      print payload
    } else {
      exit 42
    }
  }
' > "$DEST/etcd-backup.b64"

if [[ ! -s "$DEST/etcd-backup.b64" ]]; then
  log_err "remote backup produced no output; aborting"
  exit 1
fi

log_step "decoding backup tarball locally"
base64 -d "$DEST/etcd-backup.b64" > "$DEST/etcd-backup.tar.gz"
rm -f "$DEST/etcd-backup.b64"

gzip -t "$DEST/etcd-backup.tar.gz"
tar -xzf "$DEST/etcd-backup.tar.gz" -C "$DEST"
rm -f "$DEST/etcd-backup.tar.gz"

# Verify that the expected backup artifacts exist before declaring success.
if ! ls "$DEST"/snapshot_*.db >/dev/null 2>&1 \
  || ! ls "$DEST"/static_kuberesources_*.tar.gz >/dev/null 2>&1; then
  log_err "backup directory is missing expected files (snapshot_*.db and static_kuberesources_*.tar.gz):"
  ls -la "$DEST" >&2
  exit 1
fi

cat > "$DEST/metadata.json" <<EOF
{
  "cluster_name": "${CLUSTER_NAME}",
  "api_server":   "${SERVER}",
  "version":      "${CLUSTER_VERSION}",
  "source_node":  "${NODE}",
  "timestamp":    "${TS}",
  "kube_apiserver_to_kubelet_signer_not_after": "${EXPIRY}"
}
EOF

log_step "best-effort cleanup of remote staging directory"
oc debug "node/${NODE}" --quiet --to-namespace=default -- chroot /host bash -c "rm -rf '${REMOTE_OUT_DIR}'" >/dev/null 2>&1 || true

log_info "etcd backup complete: $DEST"
ls -la "$DEST" >&2
