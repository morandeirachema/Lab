locals {
  lab       = yamldecode(file("${path.module}/../config/lab.yml"))
  inventory = yamldecode(file("${path.module}/../ansible/inventory/hosts.yml"))

  nodes      = { for name, host in local.inventory.all.children.proxmox.hosts : name => host.ansible_host }
  first_node = sort(keys(local.nodes))[0]

  lan_prefix = split("/", local.lab.lan.cidr)[1]
  vxlan      = local.lab.sdn.type == "vxlan"
}

# Fail the plan early when config/lab.yml is inconsistent.
resource "terraform_data" "config_checks" {
  lifecycle {
    precondition {
      condition     = contains(["vlan", "vxlan"], local.lab.sdn.type)
      error_message = "config/lab.yml: sdn.type must be vlan or vxlan."
    }
    precondition {
      # PVE API: zone and vnet IDs are 2-8 characters, [a-zA-Z][a-zA-Z0-9]*[a-zA-Z0-9]
      condition = alltrue([
        for id in concat([local.lab.sdn.zone], keys(local.lab.sdn.vnets)) :
        can(regex("^[a-zA-Z][a-zA-Z0-9]*[a-zA-Z0-9]$", id)) && length(id) <= 8
      ])
      error_message = "config/lab.yml: the SDN zone and vnet names must be 2-8 letters or digits, starting with a letter (no - or _)."
    }
    precondition {
      condition     = contains(keys(local.nodes), local.lab.gateway.node)
      error_message = "config/lab.yml: gateway.node is not a host in ansible/inventory/hosts.yml."
    }
    precondition {
      condition     = alltrue([for name in keys(local.lab.labs) : contains(keys(local.lab.pools), name)])
      error_message = "config/lab.yml: every lab under labs needs a pool of the same name under pools (its guests go in it, and lab-ctl finds them by that name)."
    }
    precondition {
      condition     = alltrue([for n in local.lab.gateway.nets : contains(keys(local.lab.sdn.vnets), n.vnet)])
      error_message = "config/lab.yml: every gateway.nets[].vnet must be one of sdn.vnets."
    }
  }
}
