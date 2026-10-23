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

# The zone settings the "lab" applier watches. It can't watch the two zone
# resources directly: one of them always has count = 0, and OpenTofu (1.13)
# fails any plan whose replace_triggered_by has to look at a resource with no
# instances ("no change found"), which is every plan after the first apply.
# Only the attributes set above: the computed pending and state change once
# the applier has run, and would trigger it again.
resource "terraform_data" "sdn_zone" {
  triggers_replace = {
    vlan  = [for z in proxmox_sdn_zone_vlan.lab : [z.id, z.bridge]]
    vxlan = [for z in proxmox_sdn_zone_vxlan.lab : [z.id, z.peers, z.mtu]]
  }
}

resource "proxmox_sdn_applier" "lab" {
  lifecycle {
    replace_triggered_by = [
      terraform_data.sdn_zone,
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
