# The lab segments: one SDN zone (VLAN or VXLAN, per config/lab.yml) and its
# vnets, available on every node. SDN changes only take effect once applied;
# the two appliers follow the pattern in the provider's sdn_applier docs:
# "lab" applies after any change, "finalizer" applies after deletions.

resource "proxmox_sdn_zone_vlan" "lab" {
  count = local.vxlan ? 0 : 1

  id     = local.lab.sdn.zone
  bridge = local.lab.sdn.bridge

  depends_on = [proxmox_sdn_applier.finalizer]
}

resource "proxmox_sdn_zone_vxlan" "lab" {
  count = local.vxlan ? 1 : 0

  id    = local.lab.sdn.zone
  peers = values(local.nodes)
  mtu   = local.lab.sdn.vxlan_mtu

  depends_on = [proxmox_sdn_applier.finalizer]
}

resource "proxmox_sdn_vnet" "lab" {
  for_each = local.lab.sdn.vnets

  id    = each.key
  zone  = local.lab.sdn.zone
  tag   = each.value.tag
  alias = each.value.alias

  depends_on = [
    proxmox_sdn_zone_vlan.lab,
    proxmox_sdn_zone_vxlan.lab,
    proxmox_sdn_applier.finalizer,
  ]
}

resource "proxmox_sdn_applier" "lab" {
  lifecycle {
    replace_triggered_by = [
      proxmox_sdn_zone_vlan.lab,
      proxmox_sdn_zone_vxlan.lab,
      proxmox_sdn_vnet.lab,
    ]
  }

  depends_on = [
    proxmox_sdn_zone_vlan.lab,
    proxmox_sdn_zone_vxlan.lab,
    proxmox_sdn_vnet.lab,
  ]
}

resource "proxmox_sdn_applier" "finalizer" {
}
