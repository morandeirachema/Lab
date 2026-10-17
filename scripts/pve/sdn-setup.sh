#!/usr/bin/env bash
# Create or update the lab SDN zone and vnets from config/lab.env, then apply
# them to every node. Run on any one node once the cluster exists; re-run after
# adding a node (VXLAN peers) or a vnet. DRY_RUN=1 prints the pvesh calls.
set -euo pipefail

# shellcheck source=scripts/pve/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

require_root
require_cmd pvesh jq

ZONE=$LAB_SDN_ZONE
exists() { pvesh get "$1" >/dev/null 2>&1; }

# Cluster node addresses from corosync, or this host's address before a cluster exists.
node_ips() {
  local ips
  ips=$(awk '/ring0_addr/ { print $2 }' /etc/pve/corosync.conf 2>/dev/null | paste -sd, -)
  [[ -n $ips ]] || ips=$(hostname -I | awk '{ print $1 }')
  printf '%s' "$ips"
}

if ! grep -qE '^[[:space:]]*source[[:space:]]+/etc/network/interfaces\.d/\*' /etc/network/interfaces; then
  warn "/etc/network/interfaces has no 'source /etc/network/interfaces.d/*' line; SDN vnets will not come up until it does"
fi

case $LAB_SDN_TYPE in
  vlan)  settings=(--bridge "$LAB_SDN_BRIDGE") ;;
  vxlan) settings=(--peers "$(node_ips)" --mtu "$LAB_VXLAN_MTU") ;;
  *) die "LAB_SDN_TYPE must be vlan or vxlan, not '$LAB_SDN_TYPE'" ;;
esac

if exists "/cluster/sdn/zones/$ZONE"; then
  current=$(pvesh get "/cluster/sdn/zones/$ZONE" --output-format json | jq -r .type)
  [[ $current == "$LAB_SDN_TYPE" ]] \
    || die "zone '$ZONE' already exists as $current; remove it (Datacenter > SDN > Zones) before switching to $LAB_SDN_TYPE"
  log "Updating $LAB_SDN_TYPE zone '$ZONE': ${settings[*]}"
  run pvesh set "/cluster/sdn/zones/$ZONE" "${settings[@]}"
else
  log "Creating $LAB_SDN_TYPE zone '$ZONE': ${settings[*]}"
  run pvesh create /cluster/sdn/zones --zone "$ZONE" --type "$LAB_SDN_TYPE" "${settings[@]}"
fi

for entry in "${LAB_VNETS[@]}"; do
  IFS=: read -r vnet tag alias <<<"$entry"
  if exists "/cluster/sdn/vnets/$vnet"; then
    log "Updating vnet $vnet (tag $tag)"
    run pvesh set "/cluster/sdn/vnets/$vnet" --tag "$tag" --alias "$alias"
  else
    log "Creating vnet $vnet (tag $tag) in zone $ZONE"
    run pvesh create /cluster/sdn/vnets --vnet "$vnet" --zone "$ZONE" --tag "$tag" --alias "$alias"
  fi
done

log "Applying the SDN configuration on every node"
run pvesh set /cluster/sdn
log "Done. Check Datacenter > SDN in the web UI: every node should show the zone as 'available'."
