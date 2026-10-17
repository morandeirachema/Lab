output "sdn" {
  description = "The lab zone and its vnets."
  value = {
    zone  = local.lab.sdn.zone
    type  = local.lab.sdn.type
    vnets = { for id, v in proxmox_sdn_vnet.lab : id => v.tag }
  }
}

output "gateway" {
  description = "The lab gateway container; configure it next with ansible/playbooks/lab-gateway.yml."
  value = {
    vmid   = proxmox_virtual_environment_container.gateway.vm_id
    node   = local.lab.gateway.node
    lan_ip = local.gateway_lan_ip
    nets   = { for i, n in local.gateway_nets : "eth${i}" => "${n.vnet} ${n.address}" }
  }
}
