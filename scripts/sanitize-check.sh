#!/usr/bin/env bash
# scripts/sanitize-check.sh
#
# Validate that this repo doesn't contain references to specific labs,
# tenants, customers, or personally identifiable information.
#
# This is the generic version intended for the public `raskip/ocp-multus`
# repo. It scans for known leak patterns (test-lab resource names, internal
# IPs, personal UPNs) so that copy-paste from a private lab into the public
# repo is caught before push.
#
# Exit 0  — no violations
# Exit 1  — at least one violation; failing matches printed with file:line
#
# Usage: bash scripts/sanitize-check.sh

set -u

# Patterns that must NOT appear anywhere in tracked content. Add new entries
# here whenever a new customer/tenant snapshot is taken — the patterns
# capture domain names, tenant/subscription UUIDs, internal IPs, SP names,
# resource group prefixes, public IPs of jump/firewall hosts, and any
# auto-generated identifiers that leak the originating tenant.
PATTERNS=(
  'REDACTED_DOMAIN'
  'REDACTED_IDENTIFIER'
  'REDACTED_IDENTIFIER'
  'REDACTED_IDENTIFIER'
  'REDACTED_EMAIL'
  'REDACTED_UUID'
  'REDACTED_UUID'
  'REDACTED_UUID'
  'REDACTED_IDENTIFIER'
  'REDACTED_IDENTIFIER'
  'REDACTED_IDENTIFIER'
  'REDACTED_RESOURCE_GROUP'
  'REDACTED_RESOURCE_GROUP'
  'REDACTED_RESOURCE_GROUP'
  'REDACTED_VNET'
  'REDACTED_VNET'
  'REDACTED_IP'
  'REDACTED_IP'
  'REDACTED_IP'
  'REDACTED_STORAGE'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  '"auths":[[:space:]]*\{'
)

# Paths excluded from scanning. Local-only artifacts (kubeconfig, installer
# output, terraform state, downloaded binaries) and the script itself
# (which lists the patterns) are skipped.
EXCLUDES=(
  ":!scripts/sanitize-check.sh"
  ":!secrets/"
  ":!install/"
  ":!terraform/**/.terraform/"
  ":!terraform/**/terraform.tfstate*"
  ":!*.kubeconfig"
  ":!oc"
  ":!openshift-install"
  ":!lifecycle-*.log"
)

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

violations=0
total_hits=0

for p in "${PATTERNS[@]}"; do
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    hits=$(git grep -nE -I --color=never "$p" -- "${EXCLUDES[@]}" 2>/dev/null || true)
  else
    hits=$(grep -rnIE --exclude-dir=.git --exclude-dir=secrets --exclude-dir=install \
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
