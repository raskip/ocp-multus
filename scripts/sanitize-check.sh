#!/usr/bin/env bash
# scripts/sanitize-check.sh
#
# Validate that this repo doesn't contain references to specific labs,
# tenants, customers, or personally identifiable information.
#
# This is the generic version intended for the public `raskip/ocp-multus`
# repo. It scans for two classes of leak:
#
#   1. BUILTIN structural patterns (below) — generic indicators that are not
#      themselves secrets (private-key headers, embedded pull-secret `auths`
#      blocks, tracked files under secrets/). These ship in the public repo.
#
#   2. LOCAL, environment-specific patterns — your own lab/tenant identifiers
#      (domains, UPNs, subscription/tenant UUIDs, internal IPs, resource-group
#      and storage-account names). These are PII/identifiers and must NEVER be
#      committed. Keep them in a gitignored file and point the check at it:
#
#        cp .sanitize-patterns.example .sanitize-patterns.local
#        # edit .sanitize-patterns.local with YOUR values (it is gitignored)
#
#      The check auto-loads `.sanitize-patterns.local` if present, or any file
#      given via $SANITIZE_PATTERNS_FILE. This keeps your real identifiers out
#      of the public repo while still guarding every local push.
#
# Exit 0  — no violations
# Exit 1  — at least one violation; failing matches printed with file:line
#
# Usage:
#   bash scripts/sanitize-check.sh
#   SANITIZE_PATTERNS_FILE=/path/to/patterns bash scripts/sanitize-check.sh

set -u

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 1

# Generic, non-secret structural patterns. These are safe to ship publicly:
# they describe the *shape* of a leaked credential, not any specific value.
BUILTIN_PATTERNS=(
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'   # SSH/TLS private keys
  '"auths":[[:space:]]*\{'               # embedded Red Hat / registry pull secret
)

# Local, environment-specific patterns (gitignored). Add YOUR lab/tenant
# identifiers here so copy-paste from a private lab is caught before push.
PATTERNS_FILE="${SANITIZE_PATTERNS_FILE:-.sanitize-patterns.local}"

LOCAL_PATTERNS=()
if [[ -f "$PATTERNS_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip blank lines and comments.
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    LOCAL_PATTERNS+=("$line")
  done < "$PATTERNS_FILE"
else
  echo "[INFO] no local pattern file ($PATTERNS_FILE) — running BUILTIN checks only."
  echo "[INFO] copy .sanitize-patterns.example to .sanitize-patterns.local to add"
  echo "[INFO] your lab/tenant identifiers (domains, UPNs, UUIDs, IPs, RG names)."
fi

PATTERNS=( "${BUILTIN_PATTERNS[@]}" "${LOCAL_PATTERNS[@]}" )

# Paths excluded from scanning. Local-only artifacts (kubeconfig, installer
# output, terraform state, downloaded binaries) and the local pattern file
# (which lists the identifiers) are skipped.
EXCLUDES=(
  ":!scripts/sanitize-check.sh"
  ":!.sanitize-patterns.local"
  ":!secrets/"
  ":!install/"
  ":!terraform/**/.terraform/"
  ":!terraform/**/terraform.tfstate*"
  ":!*.kubeconfig"
  ":!oc"
  ":!openshift-install"
  ":!lifecycle-*.log"
)

violations=0
total_hits=0

for p in "${PATTERNS[@]}"; do
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    hits=$(git grep -nE -I --color=never "$p" -- "${EXCLUDES[@]}" 2>/dev/null || true)
  else
    hits=$(grep -rnIE --exclude-dir=.git --exclude-dir=secrets --exclude-dir=install \
                     --exclude='.sanitize-patterns.local' \
                     --exclude='*.kubeconfig' --exclude='oc' --exclude='openshift-install' \
                     --exclude='lifecycle-*.log' "$p" . 2>/dev/null || true)
  fi
  if [[ -n "$hits" ]]; then
    echo "[FAIL] pattern '$p' found:"
    echo "$hits" | sed 's/^/  /'
    n=$(echo "$hits" | wc -l)
    total_hits=$(( total_hits + n ))
    violations=$(( violations + 1 ))
  fi
done

# Structural check: tracked content under secrets/ that isn't a placeholder.
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  tracked_secrets=$(git ls-files secrets/ 2>/dev/null | grep -vE '(\.gitkeep|\.example|README\.md|README)$' || true)
  if [[ -n "$tracked_secrets" ]]; then
    echo "[FAIL] tracked content under secrets/ (should be gitignored except placeholders):"
    echo "$tracked_secrets" | sed 's/^/  /'
    violations=$(( violations + 1 ))
  fi
fi

if (( violations > 0 )); then
  echo
  echo "sanitize-check FAILED: $violations pattern violation(s), $total_hits total hit(s)."
  echo "Replace customer-specific values with placeholders before pushing."
  exit 1
fi

echo "[OK] sanitize-check passed — no disallowed patterns or tracked secret files."
