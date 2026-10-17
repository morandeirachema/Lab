# Authentication comes from the environment, never from files in this repo:
#   PROXMOX_VE_API_TOKEN  terraform@pve!provider=<secret>, written by
#                         ansible/playbooks/pve-iac.yml (the Makefile exports it)
provider "proxmox" {
  endpoint = coalesce(var.proxmox_endpoint, "https://${local.nodes[local.first_node]}:8006/")
  insecure = var.proxmox_insecure

  # Only some operations go over SSH; root on each node, keys from your ssh-agent.
  ssh {
    agent    = true
    username = "root"

    dynamic "node" {
      for_each = local.nodes
      content {
        name    = node.key
        address = node.value
      }
    }
  }
}
