output "sdn" {
  description = "The lab zone and its vnets."
  value = {
    zone  = local.lab.sdn.zone
    type  = local.lab.sdn.type
    vnets = { for id, v in proxmox_sdn_vnet.lab : id => v.tag }
  }
}
