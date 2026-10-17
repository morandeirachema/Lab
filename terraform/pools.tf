# One resource pool per lab (plus infra): the web UI can show a lab on its
# own, and permissions can later be granted per lab.
resource "proxmox_virtual_environment_pool" "lab" {
  for_each = local.lab.pools

  pool_id = each.key
  comment = each.value
}
