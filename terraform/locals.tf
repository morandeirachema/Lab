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
      condition     = contains(keys(local.nodes), local.lab.gateway.node)
      error_message = "config/lab.yml: gateway.node is not a host in ansible/inventory/hosts.yml."
    }
    precondition {
      condition     = alltrue([for n in local.lab.gateway.nets : contains(keys(local.lab.sdn.vnets), n.vnet)])
      error_message = "config/lab.yml: every gateway.nets[].vnet must be one of sdn.vnets."
    }
  }
}
