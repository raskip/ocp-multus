#!/usr/bin/env bash
# Configure the OpenShift image registry as Managed on Azure blob storage, for
# the CNF / telco profile where an in-cluster ImageStream registry is required.
#
# Prerequisite: install with AUTO_IMAGE_REGISTRY_REMOVED=false so wait-install
# does NOT set the registry to Removed (see config/cluster.cnf.example.env).
#
# This applies Option B (Managed + Azure AD / managed-identity auth) from
# docs/image-registry-options.md. For a platform-owned, pre-created storage
# account (Option C), export ACCOUNT_NAME and CONTAINER_NAME first.
#
# Requires: oc, logged in as a cluster admin.
set -euo pipefail

ACCOUNT_NAME="${ACCOUNT_NAME:-}"       # empty => let the operator create one
CONTAINER_NAME="${CONTAINER_NAME:-}"   # empty => operator default
CLOUD_NAME="${CLOUD_NAME:-AzurePublicCloud}"

patch_file="$(mktemp)"
trap 'rm -f "$patch_file"' EXIT

{
  echo "spec:"
  echo "  managementState: Managed"
  echo "  storage:"
  echo "    azure:"
  echo "      cloudName: ${CLOUD_NAME}"
  if [[ -n "$ACCOUNT_NAME" ]]; then
    echo "      accountName: ${ACCOUNT_NAME}"
  fi
  if [[ -n "$CONTAINER_NAME" ]]; then
    echo "      container: ${CONTAINER_NAME}"
  fi
  echo "      networkAccess:"
  echo "        type: External"
} > "$patch_file"

echo "Applying image-registry Managed patch:"
cat "$patch_file"

oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type=merge --patch-file="$patch_file"

echo "Waiting for image-registry to become Available (up to 10m)..."
oc wait --for=condition=Available co/image-registry --timeout=10m
oc get co image-registry
