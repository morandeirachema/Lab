# Everything that describes the lab is in config/lab.yml and
# ansible/inventory/hosts.yml; these variables only cover how to reach it.

variable "proxmox_endpoint" {
  description = "Proxmox API URL. Default: https://<first node in the inventory>:8006/"
  type        = string
  default     = null
}

variable "proxmox_insecure" {
  description = "Skip TLS verification. Proxmox ships a self-signed certificate; set false once the Mac running OpenTofu trusts the cluster CA (docs/07-remote-management.md)."
  type        = bool
  default     = true
}

variable "ssh_public_keys" {
  description = "SSH public keys for the guests OpenTofu configures: labgw's root, and the cloud-init user of obs and of the cloud_init lab VMs. make plan/apply pass the keys in your ssh-agent."
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

variable "debian_cloud_image" {
  description = "Debian 13 genericcloud image for the observability VM and the cloud_init lab VMs, pinned to a dated build in https://cloud.debian.org/images/cloud/trixie/ (sha512 from that build's SHA512SUMS)."
  type = object({
    url    = string
    sha512 = string
  })
  default = {
    url    = "https://cloud.debian.org/images/cloud/trixie/20261017-2634/debian-13-genericcloud-amd64-20261017-2634.qcow2"
    sha512 = "ec584ccabfef7120b4c4f7482adf0e615894d9292cedec446b64194b951ebe5dd97c336b5dcbae458333764b0edd516334506017f33c4f2020ef8d38b569ffe3"
  }
}
