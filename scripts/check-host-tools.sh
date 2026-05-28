#!/usr/bin/env bash
# scripts/check-host-tools.sh
#
# Verify that the installer host has the local tools this repo needs
# *before* `make verify` tries to invoke `openshift-install`, `oc`, or
# `az` (which would otherwise fail mid-flight with a cryptic
# "command not found" or a misleading error from the wrong tool).
#
# Required tools (failing any of these exits non-zero):
#   bash       >= 4
#   make       (any GNU make)
#   jq         (any version — used in 20+ scripts to parse Azure / OCP JSON)
#   az         (Azure CLI — any reasonably recent version)
#   terraform  >= 1.5
#
# `openshift-install` and `oc` are intentionally NOT checked here; they
# are downloaded by `make tools` (not necessarily present yet) and the
# existing `make verify` recipe invokes them directly with `version`.
#
# Exit:
#   0   all required tools present at acceptable versions
#   1   at least one tool missing or below required version
#
# Usage:
#   bash scripts/check-host-tools.sh
#
# Honours environment overrides for testing:
#   SKIP_BASH_CHECK=1     skip the bash version check
#   SKIP_TERRAFORM_CHECK=1  skip the terraform version check
#
set -u

REQ_BASH_MIN="4"
REQ_TERRAFORM_MIN="1.5"

# Track failures across the script.
fail=0

# Detect platform once for install-hint messages.
detect_platform() {
  if [[ "${OSTYPE:-}" == darwin* ]]; then
    echo "macos"
  elif [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}:${ID_LIKE:-}" in
      *debian*|*ubuntu*) echo "debian" ;;
      *rhel*|*fedora*|*centos*) echo "rhel" ;;
      *)                  echo "linux-other" ;;
    esac
  elif [[ -n "${ACC_TERM_ID:-}" || -n "${AZUREPS_HOST_ENVIRONMENT:-}" ]]; then
    echo "cloudshell"
  else
    echo "linux-other"
  fi
}

PLATFORM="$(detect_platform)"

# Print per-platform install hint for a given tool. Generic catch-all
# so we don't have to special-case every package name.
hint_for() {
  local tool="$1"
  case "$PLATFORM:$tool" in
    debian:az)        echo "    Debian/Ubuntu:  curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash" ;;
    debian:terraform) echo "    Debian/Ubuntu:  see https://developer.hashicorp.com/terraform/install#linux (HashiCorp APT repo)" ;;
    debian:*)         echo "    Debian/Ubuntu:  sudo apt-get install -y $tool" ;;
    rhel:az)          echo "    RHEL/Fedora:    see https://learn.microsoft.com/cli/azure/install-azure-cli-linux" ;;
    rhel:terraform)   echo "    RHEL/Fedora:    see https://developer.hashicorp.com/terraform/install#linux (HashiCorp YUM repo)" ;;
    rhel:*)           echo "    RHEL/Fedora:    sudo dnf install -y $tool" ;;
    macos:az)         echo "    macOS:          brew install azure-cli" ;;
    macos:terraform)  echo "    macOS:          brew install hashicorp/tap/terraform" ;;
    macos:bash)       echo "    macOS:          brew install bash    (then re-run with /opt/homebrew/bin/bash or /usr/local/bin/bash)" ;;
    macos:*)          echo "    macOS:          brew install $tool" ;;
    cloudshell:*)     echo "    Azure Cloud Shell: $tool should be pre-installed; report a bug if it's missing." ;;
    *:*)              echo "    Other Linux:    install '$tool' via your distro package manager." ;;
  esac
}

# Compare two dotted version strings using sort -V (version-aware sort,
# coreutils 7+). Returns 0 if $1 >= $2, 1 otherwise.
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V -r | head -n1)" == "$1" ]]
}

# Report a single tool's status. Caller supplies the printed version.
ok()   { printf '[ OK ] %-11s %s\n' "$1" "$2"; }
warn() { printf '[WARN] %-11s %s\n' "$1" "$2" >&2; }
bad()  {
  printf '[FAIL] %-11s %s\n' "$1" "$2" >&2
  hint_for "$1" >&2
  fail=1
}

# --- bash ------------------------------------------------------------------
if [[ "${SKIP_BASH_CHECK:-0}" != "1" ]]; then
  BASH_VER="${BASH_VERSINFO[0]:-0}.${BASH_VERSINFO[1]:-0}.${BASH_VERSINFO[2]:-0}"
  if (( BASH_VERSINFO[0] >= REQ_BASH_MIN )); then
    ok bash "$BASH_VER"
  else
    bad bash "$BASH_VER (need ≥ ${REQ_BASH_MIN}; macOS-native /bin/bash is 3.2 — install a newer bash via Homebrew)"
  fi
else
  warn bash "version check skipped (SKIP_BASH_CHECK=1)"
fi

# --- make ------------------------------------------------------------------
if command -v make >/dev/null 2>&1; then
  MAKE_VER="$(make --version 2>/dev/null | awk 'NR==1 {print $NF}')"
  ok make "${MAKE_VER:-unknown}"
else
  bad make "MISSING"
fi

# --- jq --------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  JQ_VER="$(jq --version 2>/dev/null | sed -E 's/^jq[ -]//')"
  ok jq "${JQ_VER:-unknown}"
else
  bad jq "MISSING"
fi

# --- az --------------------------------------------------------------------
if command -v az >/dev/null 2>&1; then
  AZ_VER="$(az --version 2>/dev/null | awk '/^azure-cli/ {print $2; exit}')"
  ok az "${AZ_VER:-unknown}"
else
  bad az "MISSING"
fi

# --- terraform -------------------------------------------------------------
if command -v terraform >/dev/null 2>&1; then
  TF_VER="$(terraform version 2>/dev/null | awk 'NR==1 {sub(/^v/,"",$2); print $2}')"
  if [[ "${SKIP_TERRAFORM_CHECK:-0}" == "1" ]]; then
    warn terraform "${TF_VER:-unknown} (version check skipped)"
  elif [[ -n "$TF_VER" ]] && version_ge "$TF_VER" "$REQ_TERRAFORM_MIN"; then
    ok terraform "$TF_VER"
  else
    bad terraform "${TF_VER:-unknown} (need ≥ ${REQ_TERRAFORM_MIN})"
  fi
else
  bad terraform "MISSING"
fi

# --- summary ---------------------------------------------------------------
if (( fail == 0 )); then
  printf '\n[ OK ] All required host tools present.\n'
  exit 0
else
  printf '\n[FAIL] One or more required host tools missing or too old.\n' >&2
  printf '       See docs/installer-host-requirements.md for the full list.\n' >&2
  exit 1
fi
