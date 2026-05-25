# OpenShift on Azure - UPI Multus demo Makefile
# Usage: make <target>   (see DEMO.md for the full runbook)

SHELL := /bin/bash
TF    ?= terraform
INSTALLER := $(CURDIR)/openshift-install
OC        := $(CURDIR)/oc
INSTALL_DIR := $(CURDIR)/install

.PHONY: help verify prereqs network upload-rhcos image install-config ignition \
        upload-ignition bootstrap control-plane destroy-bootstrap workers \
        destroy-workers destroy-control-plane destroy-image destroy-network \
        destroy-prereqs destroy clean-install

help:
	@awk '/^[a-zA-Z_-]+:/ {print $$1}' $(MAKEFILE_LIST) | sed 's/://' | sort -u

verify:
	@$(INSTALLER) version
	@$(OC) version --client
	@az account show --query '{name:name,id:id}' -o table
	@test -f config/cluster.env || (echo "ERROR: config/cluster.env missing (copy config/cluster.example.env)" && exit 1)
	@test -f secrets/pull-secret.txt || (echo "ERROR: secrets/pull-secret.txt missing" && exit 1)
	@test -f secrets/id_ed25519.pub || (echo "ERROR: secrets/id_ed25519.pub missing (run: ssh-keygen -t ed25519 -f secrets/id_ed25519 -N '')" && exit 1)

# ---- Terraform stages ----
prereqs:           ; cd terraform/00-prereqs        && $(TF) init && $(TF) apply -auto-approve
network:           ; cd terraform/01-network        && $(TF) init && $(TF) apply -auto-approve
upload-rhcos:      ; bash scripts/upload-rhcos.sh
image:             upload-rhcos
	cd terraform/02-image && $(TF) init && $(TF) apply -auto-approve
upload-ignition:   ; bash scripts/upload-ignition.sh
bootstrap:         upload-ignition
	cd terraform/03-bootstrap && $(TF) init && $(TF) apply -auto-approve
control-plane:     ; cd terraform/04-control-plane  && $(TF) init && $(TF) apply -auto-approve
workers:           ; cd terraform/05-workers        && $(TF) init && $(TF) apply -auto-approve

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
