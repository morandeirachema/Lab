locals {
  lab       = yamldecode(file("${path.module}/../config/lab.yml"))
  inventory = yamldecode(file("${path.module}/../ansible/inventory/hosts.yml"))

  nodes      = { for name, host in local.inventory.all.children.proxmox.hosts : name => host.ansible_host }
  first_node = sort(keys(local.nodes))[0]

  lan_prefix = split("/", local.lab.lan.cidr)[1]
  vxlan      = local.lab.sdn.type == "vxlan"

  # Every lab's VMs, and every guest's VMID, for the uniqueness checks below.
  all_lab_vms = flatten([for l in values(local.lab.labs) : l.vms])
  guest_ids = concat(
    [local.lab.gateway.vmid],
    local.obs_enabled ? [local.obs.vmid] : [],
    [for vm in local.all_lab_vms : vm.vmid],
  )
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
    precondition {
      condition     = alltrue([for n in local.lab.gateway.nets : !(try(n.isolated, false) && try(n.internet, false))])
      error_message = "config/lab.yml: a gateway net is either isolated or has internet: true, not both."
    }
    precondition {
      # the collector must be reachable and must reach its package mirrors
      condition     = !local.obs_enabled || !try(one([for n in local.lab.gateway.nets : n if n.vnet == local.obs.vnet]).isolated, false)
      error_message = "config/lab.yml: the observability vnet can't be an isolated gateway net."
    }
    precondition {
      # vms.tf merges every lab's VMs into one map keyed by name, and merge() keeps
      # the last of two equal keys without a word: the other VM would just vanish.
      condition     = length(distinct([for vm in local.all_lab_vms : vm.name])) == length(local.all_lab_vms)
      error_message = "config/lab.yml: VM names must be unique across all labs (labs.*.vms[].name)."
    }
    precondition {
      condition     = length(distinct(local.guest_ids)) == length(local.guest_ids)
      error_message = "config/lab.yml: every guest needs its own VMID (gateway.vmid, observability.vmid, labs.*.vms[].vmid)."
    }
  }
}
