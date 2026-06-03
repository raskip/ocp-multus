#!/usr/bin/env bash
# scripts/preflight/_lib.sh
#
# Shared helpers for `make preflight` sub-checks. Sourced, never executed.
# All checks are READ-ONLY (no az ... create / oc apply).
#
# Provides:
#   pf_pass / pf_fail / pf_warn / pf_skip / pf_info / pf_section
#   pf_load_config       — sources config/cluster.env into env (set -a)
#   pf_load_tfvars STAGE — exports `tfvars__<key>` for every assignment in
#                          terraform/<STAGE>/terraform.tfvars (best-effort
#                          parser for `key = "value"` lines)
#   pf_require_cmd       — like require_cmd but tracks pf state
#   pf_dump_summary      — print pass/fail/warn/skip totals + exit 1 if any FAIL
#
# Each sub-check should:
#   - source this lib (no exit on its own)
#   - call pf_section "Check name"
#   - call pf_pass / pf_fail / pf_warn / pf_skip with actionable messages
#   - return 0 (orchestrator aggregates failures via the counters)

set -uo pipefail

if [[ -n "${OCP_PREFLIGHT_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
OCP_PREFLIGHT_LIB_LOADED=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

PF_PASS=${PF_PASS:-0}
PF_FAIL=${PF_FAIL:-0}
PF_WARN=${PF_WARN:-0}
PF_SKIP=${PF_SKIP:-0}
export PF_PASS PF_FAIL PF_WARN PF_SKIP

# Counters are kept in env so they survive across sourced sub-checks.

_pf_color() {
  if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    case "$1" in
      green)  tput setaf 2 ;;
      red)    tput setaf 1 ;;
      yellow) tput setaf 3 ;;
      blue)   tput setaf 4 ;;
      bold)   tput bold    ;;
      reset)  tput sgr0    ;;
    esac
  fi
}

pf_section() {
  printf '\n%s=== %s ===%s\n' "$(_pf_color bold)" "$*" "$(_pf_color reset)"
}

pf_pass() {
  PF_PASS=$((PF_PASS + 1)); export PF_PASS
  printf '  %s[PASS]%s %s\n' "$(_pf_color green)" "$(_pf_color reset)" "$*"
}

pf_fail() {
  PF_FAIL=$((PF_FAIL + 1)); export PF_FAIL
  printf '  %s[FAIL]%s %s\n' "$(_pf_color red)" "$(_pf_color reset)" "$*"
}

pf_warn() {
  PF_WARN=$((PF_WARN + 1)); export PF_WARN
  printf '  %s[WARN]%s %s\n' "$(_pf_color yellow)" "$(_pf_color reset)" "$*"
}

pf_skip() {
  PF_SKIP=$((PF_SKIP + 1)); export PF_SKIP
  printf '  %s[SKIP]%s %s\n' "$(_pf_color blue)" "$(_pf_color reset)" "$*"
}

pf_info() {
  printf '         %s\n' "$*"
}

pf_load_config() {
  local config_file="${CONFIG_FILE:-$REPO_ROOT/config/cluster.env}"
  if [[ ! -f "$config_file" ]]; then
    pf_fail "config file not found: $config_file"
    pf_info "fix: cp $REPO_ROOT/config/cluster.example.env $config_file && edit"
    return 1
  fi
  set -a
  # shellcheck source=/dev/null
  source "$config_file"
  set +a
  return 0
}

# Parse one stage's terraform.tfvars into env vars prefixed `tfvars__`.
# Best-effort: handles `key = "value"`, `key = value` (numeric/bool),
# `key = "value with spaces"`. Ignores comments and complex types
# (lists, objects, heredocs) — those callers should fall back to
# `grep`/`hcl` tooling if needed.
pf_load_tfvars() {
  local stage="$1"
  local tfvars="$REPO_ROOT/terraform/$stage/terraform.tfvars"
  if [[ ! -f "$tfvars" ]]; then
    pf_warn "terraform/$stage/terraform.tfvars missing (skip: cannot read $stage settings)"
    pf_info "fix: cp $REPO_ROOT/terraform/$stage/terraform.tfvars.example $tfvars && edit"
    return 1
  fi
  local key val line
  while IFS= read -r line; do
    line="${line%%#*}"
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*\"([^\"]*)\"[[:space:]]*$ ]] || \
      [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*([^[:space:]\"\{\[]+)[[:space:]]*$ ]] || continue
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    printf -v "tfvars__${key}" '%s' "$val"
    export "tfvars__${key}"
  done < "$tfvars"
  return 0
}

pf_require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if command -v "$cmd" >/dev/null 2>&1; then
    pf_pass "$cmd available: $(command -v "$cmd")"
    return 0
  fi
  pf_fail "$cmd not found on PATH"
  [[ -n "$hint" ]] && pf_info "fix: $hint"
  return 1
}

pf_dump_summary() {
  printf '\n%s--- Preflight summary ---%s\n' "$(_pf_color bold)" "$(_pf_color reset)"
  printf '  PASS: %d   WARN: %d   FAIL: %d   SKIP: %d\n' \
    "$PF_PASS" "$PF_WARN" "$PF_FAIL" "$PF_SKIP"
  if (( PF_FAIL > 0 )); then
    printf '\n%sPreflight FAILED.%s Resolve the [FAIL] items above before running `make prereqs|network|bootstrap`.\n' \
      "$(_pf_color red)" "$(_pf_color reset)"
    return 1
  fi
  if (( PF_WARN > 0 )); then
    printf '\n%sPreflight passed with warnings.%s Review [WARN] items; they may surface later as runtime errors.\n' \
      "$(_pf_color yellow)" "$(_pf_color reset)"
  else
    printf '\n%sPreflight OK.%s\n' "$(_pf_color green)" "$(_pf_color reset)"
  fi
  return 0
}
