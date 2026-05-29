#!/usr/bin/env bash
# Save install/run credentials and local state into a private bundle.
#
# The bundle can contain cleartext secrets: kubeadmin password, kubeconfig,
# Service Principal client secret, SSH private key, pull secret, Terraform
# state, and sensitive Terraform outputs such as the optional Windows jump
# password. Never commit or share it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUT_DIR=""
FORCE=0
GIT_GUARD_NOTE=""

usage() {
  cat <<'EOF'
Usage:
  scripts/save-credentials.sh [--out <dir>] [--force]

Creates a local credential bundle. With no --out, the destination is:
  secrets/cluster-auth/<UTC timestamp>-<cluster-name>

If --out is provided, it is treated as the exact final directory. Existing
non-empty directories are refused unless --force is set.

The destination may contain cleartext secrets and Terraform state. If it is
inside this git worktree, it must be ignored by git.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --out)
      [[ -n "${2:-}" && "${2:-}" != --* ]] || { echo "ERROR: --out requires a value" >&2; exit 2; }
      OUT_DIR="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() { printf '[save-credentials] %s\n' "$*" >&2; }
warn() { printf '[save-credentials] WARN: %s\n' "$*" >&2; }
err() { printf '[save-credentials] ERROR: %s\n' "$*" >&2; }

cluster_name() {
  local cfg="$REPO_ROOT/config/cluster.env"
  local name=""
  if [[ -f "$cfg" ]]; then
    set +u
    # shellcheck source=/dev/null
    source "$cfg" >/dev/null 2>&1 || true
    set -u
    name="${CLUSTER_NAME:-}"
  fi
  if [[ -z "$name" ]]; then
    name="unknown-cluster"
  fi
  printf '%s' "$name" | tr -c '[:alnum:]_.-' '-'
}

abs_path() {
  local path="$1"
  local dir base
  if [[ -d "$path" ]]; then
    (cd "$path" && pwd -P)
    return
  fi
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  mkdir -p "$dir"
  dir="$(cd "$dir" && pwd -P)"
  printf '%s/%s\n' "$dir" "$base"
}

make_unique_default_dir() {
  local base="$REPO_ROOT/secrets/cluster-auth"
  local stamp name candidate i
  stamp="$(date -u +"%Y%m%dT%H%M%SZ")"
  name="$(cluster_name)"
  candidate="$base/${stamp}-${name}"
  if [[ ! -e "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return
  fi
  for i in $(seq 1 99); do
    candidate="$base/${stamp}-${name}-${i}"
    if [[ ! -e "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  err "could not allocate a unique destination under $base"
  exit 1
}

is_inside_repo() {
  local path="$1"
  case "$path/" in
    "$REPO_ROOT"/*) return 0 ;;
    *) return 1 ;;
  esac
}

repo_has_git_worktree() {
  git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

ensure_destination_is_safe() {
  local dest="$1"

  mkdir -p "$dest"

  shopt -s nullglob dotglob
  local entries=("$dest"/*)
  shopt -u nullglob dotglob
  local has_entries=0
  (( ${#entries[@]} > 0 )) && has_entries=1

  if ! is_inside_repo "$dest"; then
    if (( has_entries == 1 && FORCE == 0 )); then
      err "destination is not empty: $dest"
      err "choose a new --out directory or pass --force intentionally"
      exit 1
    fi
    if (( has_entries == 1 && FORCE == 1 )); then
      rm -rf "$dest"/*
      rm -rf "$dest"/.[!.]* "$dest"/..?* 2>/dev/null || true
    fi
    return 0
  fi

  if ! repo_has_git_worktree; then
    GIT_GUARD_NOTE="No Git worktree detected under $REPO_ROOT; in-repository gitignore checks were skipped. Keep this local bundle private and do not upload it back into source control."
    if (( has_entries == 1 && FORCE == 0 )); then
      err "destination is not empty: $dest"
      err "choose a new --out directory or pass --force intentionally"
      exit 1
    fi
    if (( has_entries == 1 && FORCE == 1 )); then
      rm -rf "$dest"/*
      rm -rf "$dest"/.[!.]* "$dest"/..?* 2>/dev/null || true
    fi
    return 0
  fi

  local marker rel rc
  marker="$dest/.gitignore-check-$$"
  : > "$marker"
  rel="${marker#"$REPO_ROOT"/}"
  set +e
  git -C "$REPO_ROOT" check-ignore -q -- "$rel"
  rc=$?
  set -e
  rm -f "$marker"

  case "$rc" in
    0) ;;
    1)
      err "destination is inside the repository but is not ignored by git: $dest"
      err "use an ignored path such as secrets/cluster-auth/<run-id>, or an out-of-repo path"
      exit 1
      ;;
    *)
      err "git check-ignore failed for $dest"
      exit 1
      ;;
  esac

  local rel_dest tracked
  rel_dest="${dest#"$REPO_ROOT"/}"
  tracked="$(git -C "$REPO_ROOT" ls-files -- "$rel_dest" 2>/dev/null || true)"
  if [[ -n "$tracked" ]]; then
    err "destination contains tracked files and will not be used: $dest"
    err "choose a deeper ignored directory such as secrets/cluster-auth/<run-id>"
    exit 1
  fi

  if (( has_entries == 1 && FORCE == 0 )); then
    err "destination is not empty: $dest"
    err "choose a new --out directory or pass --force intentionally"
    exit 1
  fi
  if (( has_entries == 1 && FORCE == 1 )); then
    rm -rf "$dest"/*
    rm -rf "$dest"/.[!.]* "$dest"/..?* 2>/dev/null || true
  fi
}

declare -a SAVED=()
declare -a MISSING=()
declare -a NOTES=()

record_saved() { SAVED+=("$1 -> $2"); }
record_missing() { MISSING+=("$1"); }
record_note() { NOTES+=("$1"); }

copy_file_if_present() {
  local src="$1" rel="$2" label="$3"
  if [[ -f "$src" ]]; then
    mkdir -p "$DEST/$(dirname "$rel")"
    cp -p "$src" "$DEST/$rel"
    record_saved "$label" "$rel"
  else
    record_missing "$label ($src)"
  fi
}

copy_dir_if_present() {
  local src="$1" rel="$2" label="$3"
  if [[ -d "$src" ]]; then
    mkdir -p "$DEST/$(dirname "$rel")"
    rm -rf "$DEST/$rel"
    cp -a "$src" "$DEST/$rel"
    record_saved "$label" "$rel/"
  else
    record_missing "$label ($src)"
  fi
}

copy_first_sp_json() {
  local candidates=()
  if [[ -n "${AZURE_SP_JSON:-}" ]]; then
    candidates+=("$AZURE_SP_JSON")
  elif [[ -n "${AZURE_CONFIG_DIR:-}" ]]; then
    candidates+=("$AZURE_CONFIG_DIR/osServicePrincipal.json")
  else
    candidates+=("$HOME/.azure/osServicePrincipal.json")
  fi

  local seen="" src
  for src in "${candidates[@]}"; do
    [[ -n "$src" ]] || continue
    case "|$seen|" in *"|$src|"*) continue ;; esac
    seen="$seen|$src"
    if [[ -f "$src" ]]; then
      copy_file_if_present "$src" "azure/osServicePrincipal.json" "Azure Service Principal JSON"
      record_note "SP JSON source: $src"
      return
    fi
  done
  record_missing "Azure Service Principal JSON (${candidates[*]})"
}

copy_terraform_state() {
  local stack stack_name outdir file out_json
  mkdir -p "$DEST/terraform-state" "$DEST/terraform-outputs"
  shopt -s nullglob
  for stack in "$REPO_ROOT"/terraform/*; do
    [[ -d "$stack" ]] || continue
    stack_name="$(basename "$stack")"
    outdir="$DEST/terraform-state/$stack_name"
    mkdir -p "$outdir"

    local copied=0
    for file in "$stack"/terraform.tfstate "$stack"/terraform.tfstate.backup "$stack"/*.tfvars "$stack"/*.auto.tfvars "$stack"/.terraform.lock.hcl; do
      [[ -f "$file" ]] || continue
      cp -p "$file" "$outdir/$(basename "$file")"
      copied=1
    done

    if (( copied == 1 )); then
      record_saved "Terraform local state/tfvars ($stack_name)" "terraform-state/$stack_name/"
    else
      record_missing "Terraform local state/tfvars ($stack_name)"
    fi

    if [[ -f "$stack/terraform.tfstate" && -d "$stack/.terraform" ]] && command -v terraform >/dev/null 2>&1; then
      out_json="$DEST/terraform-outputs/$stack_name.json"
      if (cd "$stack" && terraform output -json > "$out_json" 2>/dev/null); then
        if [[ -s "$out_json" ]]; then
          record_saved "Terraform outputs ($stack_name, may include sensitive values)" "terraform-outputs/$stack_name.json"
        else
          rm -f "$out_json"
          record_missing "Terraform outputs ($stack_name, empty)"
        fi
      else
        rm -f "$out_json"
        record_missing "Terraform outputs ($stack_name, terraform output failed)"
      fi
    else
      record_missing "Terraform outputs ($stack_name, no state/.terraform or terraform missing)"
    fi
  done
  shopt -u nullglob
}

write_bundle_readme() {
  cat > "$DEST/README.txt" <<'EOF'
This directory is a private OpenShift/Azure credential bundle.

It can contain cleartext secrets, including:
- Azure Service Principal client secret
- Red Hat pull secret
- SSH private key
- OpenShift kubeconfig
- kubeadmin password
- Terraform state
- Terraform outputs such as optional Windows jump-host password

Do not commit, publish, email, or share this bundle. Store it in an
approved secret location for your organisation.
EOF
}

write_inventory() {
  local inv="$DEST/inventory.txt"
  {
    printf 'Credential bundle inventory\n'
    printf 'Created UTC: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf 'Repository: %s\n' "$REPO_ROOT"
    printf 'Git HEAD: %s\n' "$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    printf 'Cluster name: %s\n' "$(cluster_name)"
    printf 'Destination: %s\n' "$DEST"
    printf '\nWARNING: this bundle can contain cleartext secrets. Do not commit or share it.\n'

    printf '\nSaved artefacts:\n'
    if (( ${#SAVED[@]} == 0 )); then
      printf '%s\n' '- none'
    else
      local item
      for item in "${SAVED[@]}"; do
        printf '%s\n' "- $item"
      done
    fi

    printf '\nMissing / skipped artefacts:\n'
    if (( ${#MISSING[@]} == 0 )); then
      printf '%s\n' '- none'
    else
      local item
      for item in "${MISSING[@]}"; do
        printf '%s\n' "- $item"
      done
    fi

    printf '\nNotes:\n'
    if (( ${#NOTES[@]} == 0 )); then
      printf '%s\n' '- none'
    else
      local item
      for item in "${NOTES[@]}"; do
        printf '%s\n' "- $item"
      done
    fi
  } > "$inv"
}

umask 077

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$(make_unique_default_dir)"
fi

DEST="$(abs_path "$OUT_DIR")"
ensure_destination_is_safe "$DEST"
chmod 700 "$DEST" 2>/dev/null || true
[[ -n "$GIT_GUARD_NOTE" ]] && record_note "$GIT_GUARD_NOTE"

log "saving credential bundle to: $DEST"

write_bundle_readme
copy_file_if_present "$REPO_ROOT/config/cluster.env" "config/cluster.env" "cluster.env"
copy_file_if_present "$REPO_ROOT/secrets/pull-secret.txt" "secrets/pull-secret.txt" "Red Hat pull secret"
copy_file_if_present "$REPO_ROOT/secrets/id_ed25519" "secrets/id_ed25519" "SSH private key"
copy_file_if_present "$REPO_ROOT/secrets/id_ed25519.pub" "secrets/id_ed25519.pub" "SSH public key"
copy_first_sp_json
copy_file_if_present "$REPO_ROOT/install-config/install-config.yaml" "install-config/install-config.yaml" "rendered install-config.yaml"
copy_dir_if_present "$REPO_ROOT/install" "install" "OpenShift install directory"
copy_file_if_present "$REPO_ROOT/.openshift_install.log" "openshift-install/root.openshift_install.log" "root openshift-install log"
copy_file_if_present "$REPO_ROOT/.openshift_install_state.json" "openshift-install/root.openshift_install_state.json" "root openshift-install state"
copy_terraform_state

chmod -R go-rwx "$DEST" 2>/dev/null || true
write_inventory
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$DEST/.complete"

log "complete: $DEST"
log "inventory: $DEST/inventory.txt"
if (( ${#MISSING[@]} > 0 )); then
  warn "some artefacts were not present yet; inspect inventory.txt"
fi
