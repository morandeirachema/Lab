# The Synology NAS as shared NFS storage, and weekly backups of the lab pools
# to it. Off until config/lab.yml says nas.enabled: true: the NFS share has to
# exist on the NAS first (docs/09-nas-and-control-node.md).

locals {
  nas         = try(local.lab.nas, { enabled = false })
  nas_enabled = try(local.nas.enabled, false)
  nas_address = try(local.inventory.all.children.nas.hosts.ds224.ansible_host, null)
}

resource "proxmox_storage_nfs" "nas" {
  count = local.nas_enabled ? 1 : 0

  id      = local.nas.storage_id
  server  = local.nas_address
  export  = local.nas.export
  content = local.nas.content
  options = try(local.nas.options, null)

  backups {
    keep_last   = try(local.nas.backup.keep_last, 3)
    keep_weekly = try(local.nas.backup.keep_weekly, 4)
  }

  lifecycle {
    precondition {
      condition     = local.nas_address != null
      error_message = "nas.enabled is true but ansible/inventory/hosts.yml has no nas group with host ds224."
    }
  }
}

# One job per pool, so a lab's guests are backed up wherever they run.
resource "proxmox_backup_job" "lab" {
  for_each = local.nas_enabled ? toset(try(local.nas.backup.pools, [])) : toset([])

  id       = "lab-${each.key}"
  comment  = "Weekly backup of the ${each.key} pool to the NAS. Managed by terraform/nas.tf."
  schedule = try(local.nas.backup.schedule, "sat 03:00")
  storage  = proxmox_storage_nfs.nas[0].id
  pool     = proxmox_virtual_environment_pool.lab[each.key].pool_id
  mode     = "snapshot"
  compress = "zstd"
  enabled  = true
}
