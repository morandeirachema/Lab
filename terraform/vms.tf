# Lab VMs from config/lab.yml (labs.<lab>.vms). Each disk image (unpacked on
# this machine by scripts/ova-unpack.sh) is uploaded to the node's import
# storage and imported as the VM's disk. VMs are built stopped: starting and
# stopping labs is scripts/lab-ctl.sh's job, so OpenTofu ignores power state.

locals {
  lab_vms = merge([
    for lab_name, lab in local.lab.labs : {
      for vm in lab.vms : vm.name => merge(vm, { lab = lab_name })
    }
  ]...)

  # VMs from disk images; the cloud_init: true ones are in cloud_vms.tf.
  image_vms = { for name, vm in local.lab_vms : name => vm if !try(vm.cloud_init, false) }

  lab_disks = merge([
    for name, vm in local.image_vms : {
      for i, d in vm.disks : "${name}-${i}" => merge(d, {
        node = vm.node
        path = abspath("${path.module}/../${d.image}")
      })
    }
  ]...)
}

resource "proxmox_virtual_environment_file" "disk_image" {
  for_each = local.lab_disks

  node_name      = each.value.node
  datastore_id   = local.lab.storage.files
  content_type   = "import"
  timeout_upload = 3600

  source_file {
    path      = each.value.path
    file_name = "${each.key}${lower(regex("\\.[A-Za-z0-9]+$", each.value.image))}"
    checksum  = fileexists(each.value.path) ? filesha256(each.value.path) : null
  }

  lifecycle {
    precondition {
      condition     = fileexists(each.value.path)
      error_message = "${each.value.image} does not exist: run scripts/ova-unpack.sh on the OVA first."
    }
  }
}

resource "proxmox_virtual_environment_vm" "lab" {
  for_each = local.image_vms

  node_name   = each.value.node
  vm_id       = each.value.vmid
  name        = each.key
  description = "${each.value.lab} lab. Disks imported from ${join(", ", [for d in each.value.disks : d.image])}. Managed by terraform/vms.tf."
  tags        = sort(["lab", each.value.lab])
  pool_id     = proxmox_virtual_environment_pool.lab[each.value.lab].pool_id

  started         = false
  on_boot         = false
  stop_on_destroy = true

  bios          = try(each.value.firmware, "bios") == "efi" ? "ovmf" : "seabios"
  scsi_hardware = "virtio-scsi-single"
  boot_order    = ["${try(each.value.bus, "sata")}0"]

  operating_system {
    type = try(each.value.os, "l26")
  }

  cpu {
    cores = each.value.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory
  }

  # VirtualBox guests have SATA (AHCI) drivers; keep that bus unless told otherwise.
  dynamic "disk" {
    for_each = { for i, d in each.value.disks : i => d }
    content {
      interface    = "${try(each.value.bus, "sata")}${disk.key}"
      datastore_id = local.lab.storage.vm
      import_from  = proxmox_virtual_environment_file.disk_image["${each.key}-${disk.key}"].id
      size         = disk.value.size_gb
      discard      = "on"
    }
  }

  dynamic "efi_disk" {
    for_each = try(each.value.firmware, "bios") == "efi" ? [1] : []
    content {
      datastore_id      = local.lab.storage.vm
      type              = "4m"
      pre_enrolled_keys = false
    }
  }

  dynamic "tpm_state" {
    for_each = try(each.value.tpm, false) ? [1] : []
    content {
      datastore_id = local.lab.storage.vm
      version      = "v2.0"
    }
  }

  # e1000 is what VirtualBox emulates by default, so the guest has its driver.
  network_device {
    bridge      = each.value.vnet
    model       = try(each.value.nic, "e1000")
    mac_address = try(each.value.mac, null)
    # A virtio NIC can take the vnet's MTU (1450 on VXLAN); emulated NICs cannot.
    mtu = local.vxlan && try(each.value.nic, "e1000") == "virtio" ? 1 : null
  }

  agent {
    enabled = try(each.value.agent, false)
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
      condition     = contains(["bios", "efi"], try(each.value.firmware, "bios"))
      error_message = "${each.key}: firmware must be bios or efi."
    }
    precondition {
      condition     = contains(["sata", "scsi", "virtio"], try(each.value.bus, "sata"))
      error_message = "${each.key}: bus must be sata, scsi or virtio (the interfaces the provider can import to)."
    }
  }

  depends_on = [proxmox_sdn_applier.lab]
}
