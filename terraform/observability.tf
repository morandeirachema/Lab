# The observability VM (Grafana Alloy, Loki, Prometheus, Grafana) from the
# Debian 13 cloud image with cloud-init, plus Proxmox's own metric push to it.
# Ansible installs the stack (ansible/playbooks/observability.yml). The disk
# layout follows the provider's cloud-image guide (virtio0, iothread, discard;
# stop_on_destroy because the image has no guest agent configured).

locals {
  obs         = try(local.lab.observability, { enabled = false })
  obs_enabled = try(local.obs.enabled, false)
  obs_ip      = try(local.inventory.all.children.observability.hosts.obs.ansible_host, null)
  obs_net     = local.obs_enabled ? try(local.net_by_vnet[local.obs.vnet], null) : null
  obs_gateway = try(local.obs_net.router, null)
  obs_prefix  = try(local.obs_net.prefix, null)
  # null-safe, so observability.enabled: false (count = 0) still validates and the
  # preconditions below can say what is missing
  obs_cidr = local.obs_ip != null && local.obs_prefix != null ? "${local.obs_ip}/${local.obs_prefix}" : null
  obs_user = try(local.inventory.all.children.observability.vars.ansible_user, "debian")
  # Proxmox tests an OpenTelemetry metric server on creation (it POSTs to it and
  # fails unless Alloy answers), so it is created only once `make obs` has run.
  obs_push = local.obs_enabled && try(local.obs.metrics_push, false)
}

resource "proxmox_virtual_environment_vm" "obs" {
  count = local.obs_enabled ? 1 : 0

  node_name   = local.obs.node
  vm_id       = local.obs.vmid
  name        = local.obs.hostname
  description = "Observability: Grafana Alloy, Loki, Prometheus, Grafana. Built by terraform/observability.tf, configured by ansible/playbooks/observability.yml."
  tags        = ["infra", "obs"]
  pool_id     = proxmox_virtual_environment_pool.lab["infra"].pool_id

  started         = true # created running; afterwards power is lab-ctl's, not OpenTofu's
  on_boot         = true
  stop_on_destroy = true

  operating_system {
    type = "l26"
  }

  cpu {
    cores = local.obs.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = local.obs.memory
  }

  disk {
    interface    = "virtio0"
    datastore_id = local.lab.storage.vm
    import_from  = proxmox_download_file.debian_cloud[local.obs.node].id
    size         = local.obs.disk_gb
    iothread     = true
    discard      = "on"
  }

  network_device {
    bridge = local.obs.vnet
    model  = "virtio"
    mtu    = local.vxlan ? 1 : null
  }

  initialization {
    # The provider's default for the cloud-init drive is local-lvm, which a ZFS install lacks.
    datastore_id = local.lab.storage.vm

    dns {
      servers = [local.obs_gateway] # labgw's dnsmasq on the obs net
    }

    ip_config {
      ipv4 {
        address = local.obs_cidr
        gateway = local.obs_gateway
      }
    }

    user_account {
      username = local.obs_user # the observability group's ansible_user
      keys     = var.ssh_public_keys
    }
  }

  lifecycle {
    ignore_changes = [started]

    precondition {
      condition     = local.obs_ip != null
      error_message = "observability.enabled is true but ansible/inventory/hosts.yml has no observability group with host obs."
    }
    precondition {
      condition     = local.obs_net != null
      error_message = "observability.vnet '${local.obs.vnet}' is not one of gateway.nets in config/lab.yml."
    }
    precondition {
      condition     = local.obs_net == null || local.obs_ip == null ? true : cidrsubnet("${local.obs_ip}/${local.obs_prefix}", 0, 0) == cidrsubnet(local.obs_net.address, 0, 0)
      error_message = "The obs host's address in the inventory is outside the ${local.obs.vnet} subnet."
    }
    precondition {
      condition     = contains(keys(local.nodes), local.obs.node)
      error_message = "observability.node '${local.obs.node}' is not a host in ansible/inventory/hosts.yml."
    }
  }

  depends_on = [proxmox_sdn_applier.lab]
}

# Every node pushes its host, guest and storage metrics to Alloy's OTLP/HTTP
# receiver. The nodes reach 10.10.40.0/24 through labgw (pve_base lab routes).
resource "proxmox_metrics_server" "obs" {
  count = local.obs_push ? 1 : 0

  name                  = "obs"
  type                  = "opentelemetry"
  server                = coalesce(local.obs_ip, "unset")
  port                  = local.obs.otlp_port
  opentelemetry_proto   = "http"
  opentelemetry_path    = "/v1/metrics"
  opentelemetry_timeout = 1 # don't let an unreachable obs hold up the push for long
}
