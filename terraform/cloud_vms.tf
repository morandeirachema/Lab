# Lab VMs built from the Debian 13 cloud image with cloud-init: entries in
# labs.<lab>.vms with cloud_init: true, for guests that are code rather than
# OVAs (the DevOps lab). A VM's address is its host of the same name in the
# lab's inventory group (child groups included); without one it takes a DHCP
# lease from labgw. Like every lab VM it is created stopped (lab-ctl starts it).

locals {
  # Each VM with its inventory address (null: a DHCP lease), its gateway net,
  # and the user cloud-init creates (the lab group's ansible_user).
  cloud_vms = {
    for name, vm in local.lab_vms : name => merge(vm, {
      ip   = try(local.lab_inventory_hosts[vm.lab][name].ansible_host, null)
      net  = try(local.net_by_vnet[vm.vnet], null)
      user = try(local.inventory.all.children[vm.lab].vars.ansible_user, "debian")
    }) if try(vm.cloud_init, false)
  }

  # The hosts of each lab's inventory group, one level of child groups included.
  lab_inventory_hosts = {
    for lab_name in keys(local.lab.labs) : lab_name => merge(
      try({ for h, v in local.inventory.all.children[lab_name].hosts : h => v }, {}),
      [for g in values(try({ for k, v in local.inventory.all.children[lab_name].children : k => v }, {})) :
      try({ for h, v in g.hosts : h => v }, {})]...
    )
  }

  # Each node that runs a cloud-image VM needs the image in its own storage.
  cloud_image_nodes = toset(concat(local.obs_enabled ? [local.obs.node] : [], [for vm in values(local.cloud_vms) : vm.node]))
}

resource "proxmox_download_file" "debian_cloud" {
  for_each = local.cloud_image_nodes

  node_name          = each.key
  datastore_id       = local.lab.storage.files
  content_type       = "import"
  url                = var.debian_cloud_image.url
  checksum           = var.debian_cloud_image.sha512
  checksum_algorithm = "sha512"
}

resource "proxmox_virtual_environment_vm" "lab_cloud" {
  for_each = local.cloud_vms

  node_name   = each.value.node
  vm_id       = each.value.vmid
  name        = each.key
  description = "${each.value.lab} lab. Debian 13 cloud image with cloud-init. Managed by terraform/cloud_vms.tf."
  tags        = sort(["lab", each.value.lab])
  pool_id     = proxmox_virtual_environment_pool.lab[each.value.lab].pool_id

  started         = false
  on_boot         = false
  stop_on_destroy = true # the cloud image has no guest agent

  operating_system {
    type = "l26"
  }

  cpu {
    cores = each.value.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    interface    = "virtio0"
    datastore_id = local.lab.storage.vm
    import_from  = proxmox_download_file.debian_cloud[each.value.node].id
    size         = try(each.value.disk_gb, 20)
    iothread     = true
    discard      = "on"
  }

  network_device {
    bridge = each.value.vnet
    model  = "virtio"
    mtu    = local.vxlan ? 1 : null
  }

  initialization {
    datastore_id = local.lab.storage.vm

    # A static address uses labgw's dnsmasq on that net; a DHCP lease brings its own.
    dynamic "dns" {
      for_each = each.value.ip != null ? [1] : []
      content {
        servers = [try(each.value.net.router, null)]
      }
    }

    ip_config {
      ipv4 {
        address = each.value.ip != null ? "${each.value.ip}/${try(each.value.net.prefix, "24")}" : "dhcp"
        gateway = each.value.ip != null ? try(each.value.net.router, null) : null
      }
    }

    user_account {
      username = each.value.user
      keys     = var.ssh_public_keys
    }
  }

  lifecycle {
    ignore_changes = [started]

    precondition {
      condition     = contains(keys(local.nodes), each.value.node)
      error_message = "${each.key}: node '${each.value.node}' is not in ansible/inventory/hosts.yml."
    }
    precondition {
      condition     = contains(keys(local.lab.sdn.vnets), each.value.vnet)
      error_message = "${each.key}: vnet '${each.value.vnet}' is not in sdn.vnets."
    }
    precondition {
      condition     = length(try(each.value.disks, [])) == 0
      error_message = "${each.key}: cloud_init: true builds the disk from the cloud image; remove disks."
    }
    precondition {
      condition = each.value.ip == null ? length(try(each.value.net.dhcp, [])) == 2 : (
        each.value.net != null &&
        try(cidrsubnet("${each.value.ip}/${each.value.net.prefix}", 0, 0) == cidrsubnet(each.value.net.address, 0, 0), false)
      )
      error_message = "${each.key}: give it an address in the ${each.value.lab} inventory group, inside the ${each.value.vnet} gateway net, or put it on a gateway net with a DHCP range."
    }
  }

  depends_on = [proxmox_sdn_applier.lab]
}
