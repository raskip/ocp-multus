#!/usr/bin/env bash
# Read-only discovery for routed Multus and CUDN/BGP design work.
#
# Collects the OpenShift network mode plus the Azure VNet, subnets, peerings,
# worker NICs, effective routes, and visible Route Server peers. It creates or
# changes no resources.
#
# Usage:
#   make routing-discovery
#   scripts/routing-discovery.sh --out /tmp/ocp-routing.txt
#   scripts/routing-discovery.sh --skip-effective-routes
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/lib/common.sh"

OUT=""
SKIP_EFFECTIVE=0

usage() {
  sed -n '2,12p' "$0"
}

while (( $# > 0 )); do
  case "$1" in
    --out)
      [[ $# -ge 2 ]] || {
        echo "ERROR: --out requires a path" >&2
        exit 2
      }
      OUT="$2"
      shift 2
      ;;
    --skip-effective-routes)
      SKIP_EFFECTIVE=1
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

if [[ -n "$OUT" ]]; then
  mkdir -p "$(dirname "$OUT")"
  exec > >(tee "$OUT") 2>&1
fi

load_config
require_cmd az jq
require_az

az_json() {
  local description="$1"
  shift
  log_step "$description"
  if ! "$@" -o json | jq .; then
    log_warn "query failed; continue with the remaining read-only checks"
  fi
}

resource_group_from_id() {
  awk -F/ '{
    for (i = 1; i <= NF; i++) {
      if ($i == "resourceGroups") {
        print $(i + 1)
        exit
      }
    }
  }' <<< "$1"
}

log_step "Discovery context"
printf 'timestamp_utc: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
printf 'cluster_name: %s\n' "$CLUSTER_NAME"
printf 'workload_resource_group: %s\n' "$WORKLOAD_RESOURCE_GROUP"
printf 'network_resource_group: %s\n' "${NETWORK_RESOURCE_GROUP:-<unset>}"
printf 'virtual_network: %s\n' "${VIRTUAL_NETWORK:-<unset>}"
printf 'configured_machine_network: %s\n' "${MACHINE_NETWORK_CIDR:-<unset>}"
printf 'configured_cluster_network: %s\n' "${CLUSTER_NETWORK_CIDR:-<unset>}"
printf 'configured_service_network: %s\n' "${SERVICE_NETWORK_CIDR:-<unset>}"
printf 'configured_multus_subnet: %s\n' "${SUBNET_MULTUS_CIDR:-<unset>}"
printf 'configured_sriov_subnet: %s\n' "${SUBNET_SRIOV_CIDR:-<unset>}"
printf 'configured_architecture: %s\n' "${ARCHITECTURE:-<unset>}"

if [[ -z "${NETWORK_RESOURCE_GROUP:-}" || -z "${VIRTUAL_NETWORK:-}" ]]; then
  log_err "NETWORK_RESOURCE_GROUP and VIRTUAL_NETWORK are required in config/cluster.env"
  exit 1
fi

az_json "Azure account" \
  az account show --query '{subscriptionName:name,subscriptionId:id,tenantId:tenantId}'

az_json "Spoke VNet and address spaces" \
  az network vnet show \
    --resource-group "$NETWORK_RESOURCE_GROUP" \
    --name "$VIRTUAL_NETWORK" \
    --query '{name:name,id:id,location:location,addressSpaces:addressSpace.addressPrefixes,dnsServers:dhcpOptions.dnsServers}'

az_json "Spoke subnets, NSGs, and route tables" \
  az network vnet subnet list \
    --resource-group "$NETWORK_RESOURCE_GROUP" \
    --vnet-name "$VIRTUAL_NETWORK" \
    --query '[].{name:name,addressPrefix:addressPrefix,addressPrefixes:addressPrefixes,nsg:networkSecurityGroup.id,routeTable:routeTable.id,delegations:delegations[].serviceName}'

PEERINGS="$(
  az network vnet peering list \
    --resource-group "$NETWORK_RESOURCE_GROUP" \
    --vnet-name "$VIRTUAL_NETWORK" \
    -o json 2>/dev/null || echo '[]'
)"
log_step "Spoke VNet peerings"
jq '[.[] | {
  name,
  state: .peeringState,
  remoteVnet: .remoteVirtualNetwork.id,
  allowVirtualNetworkAccess,
  allowForwardedTraffic,
  allowGatewayTransit,
  useRemoteGateways
}]' <<< "$PEERINGS"

VWAN_CONNECTED=0
if jq -e '
  any(.[];
    (.name | startswith("RemoteVnetToHubPeering_")) or
    ((.remoteVirtualNetwork.id // "") | test("/virtualNetworks/HV_vwan-hub-"; "i"))
  )
' <<< "$PEERINGS" >/dev/null; then
  VWAN_CONNECTED=1
  log_warn "the spoke appears connected to an Azure Virtual WAN hub"
  log_warn "Azure Route Server cannot be deployed in a VNet connected to Virtual WAN"
  log_warn "evaluate direct BGP peering from approved node/router endpoints to the Virtual WAN hub router instead"
fi

NICS="$(
  az network nic list \
    --resource-group "$WORKLOAD_RESOURCE_GROUP" \
    --query "[?starts_with(name, 'nic-worker-')]" \
    -o json 2>/dev/null || echo '[]'
)"
log_step "Worker NIC inventory"
jq '[.[] | {
  name,
  vm: .virtualMachine.id,
  ipForwarding: (.enableIPForwarding // .enableIpForwarding),
  acceleratedNetworking: .enableAcceleratedNetworking,
  macAddress,
  ipConfigurations: [.ipConfigurations[] | {
    name,
    primary,
    privateIpAddress: (.privateIPAddress // .privateIpAddress),
    privateIpAddressVersion: (.privateIPAddressVersion // .privateIpAddressVersion),
    subnet: .subnet.id
  }]
}]' <<< "$NICS"

if (( SKIP_EFFECTIVE == 0 )); then
  log_step "Worker NIC effective routes"
  mapfile -t NIC_NAMES < <(jq -r '.[].name' <<< "$NICS")
  if (( ${#NIC_NAMES[@]} == 0 )); then
    log_warn "no worker NICs found in $WORKLOAD_RESOURCE_GROUP"
  fi
  for nic in "${NIC_NAMES[@]}"; do
    printf '\n--- %s ---\n' "$nic"
    if ! az network nic show-effective-route-table \
      --resource-group "$WORKLOAD_RESOURCE_GROUP" \
      --name "$nic" \
      --query 'value[].{prefix:addressPrefix,nextHopType:nextHopType,nextHopIp:nextHopIpAddress,source:source,state:state}' \
      -o json | jq .; then
      log_warn "effective routes unavailable for $nic (the attached VM might be stopped)"
    fi
  done
else
  log_step "Worker NIC effective routes"
  log_warn "skipped by --skip-effective-routes"
fi

CURRENT_SUBSCRIPTION="$(az account show --query id -o tsv)"
mapfile -t DISCOVERY_SUBSCRIPTIONS < <(
  {
    printf '%s\n' "$CURRENT_SUBSCRIPTION"
    jq -r '.[].remoteVirtualNetwork.id // empty' <<< "$PEERINGS" \
      | awk -F/ '{
          for (i = 1; i <= NF; i++) {
            if ($i == "subscriptions") {
              print $(i + 1)
              break
            }
          }
        }'
  } | sort -u
)

ROUTE_SERVERS='[]'
for subscription in "${DISCOVERY_SUBSCRIPTIONS[@]}"; do
  if hubs="$(
    az resource list \
      --subscription "$subscription" \
      --resource-type Microsoft.Network/virtualHubs \
      -o json 2>/dev/null
  )"; then
    ROUTE_SERVERS="$(
      jq -s 'add' \
        <(printf '%s\n' "$ROUTE_SERVERS") \
        <(jq --arg subscription "$subscription" \
          '[.[] |
            select(((.kind // "") | ascii_downcase) == "routeserver") |
            {name, id, resourceGroup, location, subscription}]' <<< "$hubs")
    )"
  else
    log_warn "cannot enumerate Route Servers in subscription $subscription"
  fi
done
log_step "Visible Azure Route Servers"
jq . <<< "$ROUTE_SERVERS"
if (( VWAN_CONNECTED == 1 )); then
  log_warn "Route Server is not the expected control plane for this spoke while its Virtual WAN connection remains"
fi

mapfile -t ROUTE_SERVER_ROWS < <(jq -r '.[] | [.name, .id] | @tsv' <<< "$ROUTE_SERVERS")
for row in "${ROUTE_SERVER_ROWS[@]}"; do
  IFS=$'\t' read -r rs_name rs_id <<< "$row"
  rs_rg="$(resource_group_from_id "$rs_id")"
  printf '\n--- Route Server %s/%s BGP peers ---\n' "$rs_rg" "$rs_name"
  if ! az network routeserver peering list \
    --resource-group "$rs_rg" \
    --routeserver "$rs_name" \
    --query '[].{name:name,peerIp:peerIp,peerAsn:peerAsn,provisioningState:provisioningState}' \
    -o json | jq .; then
    log_warn "could not list peers for Route Server $rs_rg/$rs_name"
  fi
done

az_json "Visible ExpressRoute circuits" \
  az network express-route list \
    --query '[].{name:name,resourceGroup:resourceGroup,location:location,serviceProvider:serviceProviderProperties.serviceProviderName,peeringLocation:serviceProviderProperties.peeringLocation,provisioningState:provisioningState,serviceProviderState:serviceProviderProvisioningState}'

log_step "Visible VNet gateways"
VNET_GATEWAYS='[]'
for subscription in "${DISCOVERY_SUBSCRIPTIONS[@]}"; do
  if gateways="$(
    az resource list \
      --subscription "$subscription" \
      --resource-type Microsoft.Network/virtualNetworkGateways \
      -o json 2>/dev/null
  )"; then
    VNET_GATEWAYS="$(
      jq -s 'add' \
        <(printf '%s\n' "$VNET_GATEWAYS") \
        <(jq --arg subscription "$subscription" \
          '[.[] | {name,resourceGroup,location,subscription,id}]' <<< "$gateways")
    )"
  else
    log_warn "cannot enumerate VNet gateways in subscription $subscription"
  fi
done
jq . <<< "$VNET_GATEWAYS"

log_step "Visible Virtual WAN hubs"
VIRTUAL_WAN_HUBS='[]'
for subscription in "${DISCOVERY_SUBSCRIPTIONS[@]}"; do
  if hubs="$(
    az resource list \
      --subscription "$subscription" \
      --resource-type Microsoft.Network/virtualHubs \
      -o json 2>/dev/null
  )"; then
    VIRTUAL_WAN_HUBS="$(
      jq -s 'add' \
        <(printf '%s\n' "$VIRTUAL_WAN_HUBS") \
        <(jq --arg subscription "$subscription" \
          '[.[] |
            select(((.kind // "") | ascii_downcase) != "routeserver") |
            {name,resourceGroup,location,subscription,kind,id}]' <<< "$hubs")
    )"
  else
    log_warn "cannot enumerate Virtual WAN hubs in subscription $subscription"
  fi
done
jq . <<< "$VIRTUAL_WAN_HUBS"

log_step "OpenShift network capabilities"
if ! command -v oc >/dev/null 2>&1 && [[ -x "$REPO_ROOT/oc" ]]; then
  export PATH="$REPO_ROOT:$PATH"
fi
if command -v oc >/dev/null 2>&1 && oc whoami >/dev/null 2>&1; then
  oc get clusterversion version \
    -o jsonpath='version={.status.desired.version} channel={.spec.channel} available={.status.conditions[?(@.type=="Available")].status}{"\n"}' \
    || true
  oc get infrastructure cluster \
    -o jsonpath='platform={.status.platformStatus.type} infrastructureName={.status.infrastructureName} controlPlaneTopology={.status.controlPlaneTopology} infrastructureTopology={.status.infrastructureTopology}{"\n"}' \
    || true
  oc get networks.operator.openshift.io cluster \
    -o jsonpath='networkType={.spec.defaultNetwork.type} clusterNetwork={range .spec.clusterNetwork[*]}{.cidr}/{.hostPrefix} {end} serviceNetwork={.spec.serviceNetwork}{"\n"}' \
    || true
  oc get featuregate cluster \
    -o jsonpath='featureSet={.spec.featureSet}{"\n"}' \
    || true
  printf 'api_resources:\n'
  for resource in \
    userdefinednetworks.k8s.ovn.org \
    clusteruserdefinednetworks.k8s.ovn.org \
    routeadvertisements.k8s.ovn.org \
    frrconfigurations.frrk8s.metallb.io; do
    if oc api-resources --api-group="${resource#*.}" -o name 2>/dev/null \
      | grep -qx "$resource"; then
      printf '  %s: available\n' "$resource"
    else
      printf '  %s: unavailable\n' "$resource"
    fi
  done
  printf 'nodes:\n'
  oc get nodes -o wide || true
else
  log_warn "oc is not logged in or the private API is unreachable; cluster-side discovery skipped"
fi

log_step "Interpretation checklist"
cat <<'EOF'
- A CUDN route-advertisement experiment requires APIs and an OpenShift version
  that contain RouteAdvertisements and FRR-K8s integration.
- A successful Azure experiment does not change Red Hat's documented platform
  support boundary.
- If the spoke is connected to Azure Virtual WAN, do not deploy Azure Route
  Server in that spoke. Evaluate Virtual WAN hub BGP peering with approved
  node/router endpoints in the directly connected VNet.
- The required workload model remains default eth0 plus a separately routed
  net1. A primary CUDN alone does not satisfy that requirement.
- Dynamically advertised pod prefixes must not overlap the VNet, peered VNets,
  OpenShift defaults/services, or on-premises routes.
- Confirm a return route from on-premises before interpreting outbound-only
  connectivity as success.
- Save output outside the repository or in an ignored local file; it contains
  environment-specific resource names, IDs, and addresses.
EOF

[[ -n "$OUT" ]] && log_info "discovery output written to $OUT"
