# The lab gateway container. OpenTofu builds it; Ansible configures what runs
# inside (ansible/playbooks/lab-gateway.yml): dnsmasq and nftables.

locals {
  gateway_lan_ip = local.inventory.all.children.lab_gateway.hosts.labgw.ansible_host
  # eth1, eth2, ... in the order of gateway.nets in config/lab.yml
  gateway_nets = { for i, net in local.lab.gateway.nets : i + 1 => net }
}

resource "proxmox_download_file" "debian_ct" {
  node_name          = local.lab.gateway.node
  datastore_id       = local.lab.storage.files
  content_type       = "vztmpl"
  url                = var.debian_ct_template.url
  checksum           = var.debian_ct_template.sha512
  checksum_algorithm = "sha512"
}

resource "proxmox_virtual_environment_container" "gateway" {
  node_name   = local.lab.gateway.node
  vm_id       = local.lab.gateway.vmid
  description = "Lab gateway: DHCP/DNS and routing for the lab vnets. Built by terraform/gateway.tf, configured by ansible/playbooks/lab-gateway.yml."
  tags        = ["infra", "lab"]
  pool_id     = proxmox_virtual_environment_pool.lab["infra"].pool_id

  unprivileged  = true
  started       = true # created running; afterwards power is lab-ctl's, not OpenTofu's
  start_on_boot = true

  features {
    nesting = true
  }

  startup {
    order = 1
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 256
    swap      = 0
  }

  disk {
    datastore_id = local.lab.storage.vm
    size         = 2
  }

  operating_system {
    template_file_id = proxmox_download_file.debian_ct.id
    type             = "debian"
  }

  initialization {
    hostname = local.lab.gateway.hostname

    dns {
      servers = [local.lab.lan.dns]
    }

    # eth0: home LAN
    ip_config {
      ipv4 {
        address = "${local.gateway_lan_ip}/${local.lan_prefix}"
        gateway = local.lab.lan.gateway
      }
    }

    dynamic "ip_config" {
      for_each = local.gateway_nets
      content {
        ipv4 {
          address = ip_config.value.address
        }
      }
    }

    user_account {
      keys = var.ssh_public_keys
    }
  }

  network_interface {
    name     = "eth0"
    bridge   = local.lab.lan.bridge
    firewall = false
  }

  dynamic "network_interface" {
    for_each = local.gateway_nets
    content {
      name     = "eth${network_interface.key}"
      bridge   = network_interface.value.vnet
      firewall = false
      mtu      = local.vxlan ? local.lab.sdn.vxlan_mtu : null
    }
  }

  lifecycle {
    ignore_changes = [started]
  }

  depends_on = [proxmox_sdn_applier.lab, terraform_data.config_checks]
}
