# OpenShift on Azure - UPI Multus demo Makefile
# Usage: make <target>   (see DEMO.md for the full runbook)

SHELL := /bin/bash
TF    ?= terraform
INSTALLER := $(CURDIR)/openshift-install
OC        := $(CURDIR)/oc
INSTALL_DIR := $(CURDIR)/install

.PHONY: help verify prereqs network upload-rhcos image install-config ignition \
        tfvars tools preflight \
        upload-ignition bootstrap control-plane destroy-bootstrap workers \
        destroy-workers destroy-control-plane destroy-image destroy-network \
        destroy-prereqs destroy clean-install \
        etcd-backup cluster-shutdown cluster-shutdown-fast cluster-startup \
        workers-down workers-up cluster-status \
        ingress-hostnetwork image-registry-removed

help:
	@awk '/^[a-zA-Z_-]+:/ {print $$1}' $(MAKEFILE_LIST) | sed 's/://' | sort -u

# Download matching openshift-install + oc for the current host (autodetected
# with uname). Override via OCP_VERSION (default: stable-4.18). Independent of
# the cluster's CPU architecture (see CPU-ARCHITECTURE.md).
tools:
	@bash scripts/fetch-openshift-tools.sh

verify:
	@$(INSTALLER) version
	@$(OC) version --client
	@az account show --query '{name:name,id:id}' -o table
	@test -f config/cluster.env || (echo "ERROR: config/cluster.env missing (copy config/cluster.example.env)" && exit 1)
	@test -f secrets/pull-secret.txt || (echo "ERROR: secrets/pull-secret.txt missing" && exit 1)
	@test -f secrets/id_ed25519.pub || (echo "ERROR: secrets/id_ed25519.pub missing (run: ssh-keygen -t ed25519 -f secrets/id_ed25519 -N '')" && exit 1)

# Read-only Azure-side prerequisite checks. Catches misconfigured RBAC,
# missing VNet, weak NSG rules, missing UDR attach, insufficient vCPU
# quota, missing DNS delegation permission, broken peering, missing
# firewall policy, and a malformed osServicePrincipal.json before they
# turn into cryptic Terraform apply errors. See docs/preflight-checklist.md.
preflight:
	@bash scripts/preflight-checks.sh

# ---- Terraform stages ----
# tfvars renders ARCHITECTURE + VM sizes from config/cluster.env into each
# stack as *.auto.tfvars (gitignored) so cluster.env is the single source of truth.
tfvars: verify
	@bash scripts/render-tfvars.sh

prereqs:           ; cd terraform/00-prereqs        && $(TF) init && $(TF) apply -auto-approve
network:           tfvars
	cd terraform/01-network        && $(TF) init && $(TF) apply -auto-approve
upload-rhcos:      ; bash scripts/upload-rhcos.sh
image:             tfvars upload-rhcos
	cd terraform/02-image && $(TF) init && $(TF) apply -auto-approve
upload-ignition:   ; bash scripts/upload-ignition.sh
bootstrap:         tfvars upload-ignition
	cd terraform/03-bootstrap && $(TF) init && $(TF) apply -auto-approve
control-plane:     tfvars
	cd terraform/04-control-plane  && $(TF) init && $(TF) apply -auto-approve
workers:           tfvars
	cd terraform/05-workers        && $(TF) init && $(TF) apply -auto-approve

destroy-workers:        ; cd terraform/05-workers       && $(TF) destroy -auto-approve
destroy-bootstrap:      ; cd terraform/03-bootstrap     && $(TF) destroy -auto-approve
destroy-control-plane:  ; cd terraform/04-control-plane && $(TF) destroy -auto-approve
destroy-image:          ; cd terraform/02-image         && $(TF) destroy -auto-approve
destroy-network:        ; cd terraform/01-network       && $(TF) destroy -auto-approve
destroy-prereqs:        ; cd terraform/00-prereqs       && $(TF) destroy -auto-approve

destroy: destroy-workers destroy-control-plane destroy-bootstrap destroy-image destroy-network destroy-prereqs clean-install

# ---- Installer artifacts ----
install-config: verify
	@bash scripts/render-install-config.sh

ignition: install-config
	@rm -rf $(INSTALL_DIR)/manifests $(INSTALL_DIR)/openshift $(INSTALL_DIR)/*.ign $(INSTALL_DIR)/auth || true
	@cp install-config/install-config.yaml $(INSTALL_DIR)/install-config.yaml
	@$(INSTALLER) --dir=$(INSTALL_DIR) create manifests
	@rm -f $(INSTALL_DIR)/openshift/99_openshift-cluster-api_master-machines-*.yaml \
	       $(INSTALL_DIR)/openshift/99_openshift-cluster-api_worker-machineset-*.yaml \
	       $(INSTALL_DIR)/openshift/99_openshift-machine-api_master-control-plane-machine-set.yaml || true
	@$(INSTALLER) --dir=$(INSTALL_DIR) create ignition-configs

clean-install:
	@rm -rf $(INSTALL_DIR)

# ---- Day-2 cluster lifecycle (see OPERATIONS.md) ----
# B44: env-var overrides so callers can pass extra flags to lifecycle
# scripts via make. Examples:
#   make cluster-shutdown SHUTDOWN_FLAGS="--no-backup --yes"
#   make cluster-startup  STARTUP_FLAGS="--timeout 20"
#   make etcd-backup      ETCD_BACKUP_FLAGS="--out /tmp/etcd-backups"
ETCD_BACKUP_FLAGS ?=
SHUTDOWN_FLAGS    ?=
STARTUP_FLAGS     ?=
SCALE_FLAGS       ?=
STATUS_FLAGS      ?=

etcd-backup:        ; bash scripts/cluster-etcd-backup.sh $(ETCD_BACKUP_FLAGS)
cluster-shutdown:   ; bash scripts/cluster-shutdown.sh $(SHUTDOWN_FLAGS)
cluster-shutdown-fast: ; bash scripts/cluster-shutdown.sh --fast $(SHUTDOWN_FLAGS)
cluster-startup:    ; bash scripts/cluster-startup.sh $(STARTUP_FLAGS)
workers-down:       ; bash scripts/cluster-scale-workers.sh down $(SCALE_FLAGS)
workers-up:         ; bash scripts/cluster-scale-workers.sh up $(SCALE_FLAGS)
cluster-status:     ; bash scripts/cluster-status.sh $(STATUS_FLAGS)

# ---- Post-install workarounds for restricted tenants (see docs/) ----
# Patch the default IngressController to HostNetwork. Use when this repo's
# terraform/01-network/ pre-creates an internal apps LB (lb-ingress-internal-*)
# with workers in its backend pool — the default LoadBalancerService strategy
# would provision a second LB and conflict. See DEMO.md "Post-install ingress
# step" for the full explanation.
ingress-hostnetwork:
	@bash scripts/ingress-hostnetwork.sh

# Set the image-registry operator to Removed. Use when the tenant blocks
# shared-key auth on storage accounts (allowSharedKeyAccess=false) and
# you don't need an in-cluster registry. Idempotent. See
# docs/image-registry-options.md for the Managed-with-AAD alternatives.
image-registry-removed:
	@$(OC) patch configs.imageregistry.operator.openshift.io/cluster \
	  --type=merge \
	  -p '{"spec":{"managementState":"Removed"}}'
	@$(OC) wait --for=condition=Available co/image-registry --timeout=10m
