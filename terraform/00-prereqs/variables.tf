variable "cluster_subscription_id" {
  description = "Azure subscription where the OpenShift cluster resources are deployed."
  type        = string
}

variable "dns_subscription_id" {
  description = "Azure subscription hosting the parent public DNS zone."
  type        = string
}

variable "location" {
  type    = string
  default = "northeurope"
}

variable "cluster_name" {
  type    = string
  default = "lab"
}

variable "base_domain" {
  type    = string
  default = "ocp.example.com"
}

# B62 fix: openshift-install's ingress-operator (dns-controller) looks up
# the private DNS zone for `*.apps` records by EXACT match of
# "${cluster_name}.${base_domain}". With the legacy layout (zone name ==
# base_domain), the ingress-operator could not find the zone and the
# `*.apps` records were never created, causing the install to hang at
# wait-for-install-complete with the ingress ClusterOperator Degraded.
#
# Default (new layout): private DNS zone is named
#   "${cluster_name}.${base_domain}"   e.g. "lab.ocp.example.com"
# and the static api / api-int A-records inside it use the short name
#   "api" / "api-int"                  → FQDN "api.lab.ocp.example.com"
# The ingress-operator then writes `*.apps` into the same zone with the
# short name, producing "*.apps.lab.ocp.example.com".
#
# Legacy layout (use_legacy_dns_layout = true): zone is named
#   "${base_domain}"                   e.g. "ocp.example.com"
# and records use long names "api.${cluster_name}" etc. This produces
# the SAME FQDN, but the ingress-operator cannot find its zone object
# and the install hangs.
#
# Set this to true ONLY if you have an existing cluster created with the
# legacy layout and cannot migrate (zone name change is a TF destroy +
# create — recreates all records and breaks any external DNS forwarders
# pinned to the zone-resource-id).
variable "use_legacy_dns_layout" {
  description = "When false (default), private DNS zone is created as $${cluster_name}.$${base_domain} so the ingress-operator's dns-controller can write *.apps records. Set to true only for backward compat with pre-B62-fix installs."
  type        = bool
  default     = false
}

# When false (default), the repo provisions NO public DNS: it does not look
# up the parent public zone, create the public child sub-zone, or write the
# NS delegation record. This is the internal-only posture — the cluster's
# api / api-int / *.apps records are served by the Azure PRIVATE DNS zone
# (azurerm_private_dns_zone.cluster) which is VNet-linked and never public.
#
# Set to true only when you actually want a delegated public sub-zone for the
# OpenShift base domain (e.g. an externally reachable cluster, or to satisfy
# an OpenShift Azure installer that validates a public base-domain zone for
# baseDomainResourceGroupName). When true, parent_dns_zone /
# parent_dns_resource_group / dns_subscription_id must point at a real parent
# public zone you control. See docs/dns-internal-only.md.
variable "create_public_dns" {
  description = "When true, create the public child sub-zone and NS delegation in the parent public DNS zone. Default false = internal-only (private DNS zone only)."
  type        = bool
  default     = false
}

variable "parent_dns_zone" {
  type    = string
  default = "example.com"
}

variable "parent_dns_resource_group" {
  type    = string
  default = "rg-dns-public-example"
}

variable "workload_resource_group_name" {
  type    = string
  default = "rg-ocp-lab"
}

variable "vnet_name" {
  type    = string
  default = "vnet-ocp-example"
}

variable "vnet_resource_group" {
  type    = string
  default = "rg-network-example"
}

variable "tags" {
  type = map(string)
  default = {
    project  = "ocp-lab"
    owner    = "platform-team"
    workload = "openshift-multus-poc"
  }
}
