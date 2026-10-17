# Everything that describes the lab is in config/lab.yml and
# ansible/inventory/hosts.yml; these variables only cover how to reach it.

variable "proxmox_endpoint" {
  description = "Proxmox API URL. Default: https://<first node in the inventory>:8006/"
  type        = string
  default     = null
}

variable "proxmox_insecure" {
  description = "Skip TLS verification. Proxmox ships a self-signed certificate; set false once your Mac trusts the cluster CA (docs/06-remote-management.md)."
  type        = bool
  default     = true
}

variable "ssh_public_keys" {
  description = "SSH public keys installed for root in the lab containers (the gateway)."
  type        = list(string)
  default     = []
}

variable "debian_ct_template" {
  description = "Debian 13 container template, from http://download.proxmox.com/images/aplinfo-pve-9.dat."
  type = object({
    url    = string
    sha512 = string
  })
  default = {
    url    = "http://download.proxmox.com/images/system/debian-13-standard_13.6-1_amd64.tar.zst"
    sha512 = "4c0c27ca6ceab5ef0b84db57825a00f26157ef1854bafe97297813e1cbe8ecb8cc9c453cab6b3b0efe1ba193a50c47ece1e41d950e411b8730b835b71e9e754b"
  }
}
