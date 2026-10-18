# 3. Install Proxmox VE on a node

Repeat this for each node. It is the only step that cannot be code, because there is
nothing to run code on yet.

## On the Mac, once

With [Homebrew](https://brew.sh) installed:

```sh
git clone https://github.com/morandeirachema/Lab.git && cd Lab
make tools            # the Brewfile: Ansible, OpenTofu, jq, the linters, gnupg, 7-Zip
make control          # ~/.ssh/lab.conf from the inventory: ssh pve1, ssh labgw, ssh obs
make check            # everything validates offline before you touch a node
```

`make control` writes one `Host` entry per inventory host (address and user) and adds
`Include` for it at the top of `~/.ssh/config`. Re-run it whenever the inventory changes.

## Installer

1. Download the current **Proxmox VE 9.x** ISO from <https://www.proxmox.com/en/downloads>
   (9.2 was released on 21 May 2026, on Debian 13). Verify its checksum against the
   download page.
2. Write it to a USB stick. The *Prepare Installation Media* section of the
   [installation guide](https://pve.proxmox.com/pve-docs/chapter-pve-installation.html)
   covers macOS.
3. Set the BIOS as in [01-hardware.md](01-hardware.md#bios-settings-s12-pro), then
   boot the stick.
4. Installer choices:

| Field | Value | Why |
|---|---|---|
| Target disk filesystem | **ZFS (RAID0)** on the single disk | Gives `local-zfs`, which `config/lab.yml` uses. It also gives snapshots and, later, replication between nodes |
| Hostname (FQDN) | `pve1.home.arpa`, `pve2.home.arpa`, … | The short name must match `ansible/inventory/hosts.yml` |
| IP address | the static address from the inventory | Outside your router's DHCP pool |
| Gateway | your router | Same as `lan.gateway` in `config/lab.yml` |
| DNS | Pi-hole on the NAS, `192.168.1.219`; add the router as a second server afterwards | Same as `lan.dns`; the second server covers NAS restarts |

If you install on ext4/LVM instead, the VM storage is `local-lvm`: set `storage.vm` in
`config/lab.yml` to match. Every node must use the same layout.

Since 9.1 the installer enables the `import` content type on the storages it creates.
`make iac` adds it only where it is missing.

## First contact from the Mac

```sh
ssh pve1                                       # accept the host key, then exit
ssh-copy-id pve1                               # key login for Ansible and OpenTofu (root password once)
```

Do this for every node. Then baseline them:

```sh
make ping     # Ansible reaches the nodes
make nodes    # repos, full upgrade, tools, ZFS ARC cap, gateway kernel modules
```

`make nodes` runs one node at a time. It disables the enterprise repository
(`Enabled: no`) and uses `pve-no-subscription`. It leaves passwords enabled on SSH until
you set `pve_base_ssh_disable_passwords: true`; do that once key login works. Reboot a
node yourself after a kernel upgrade, or set `pve_base_reboot: true`.

Next: [form the cluster](04-cluster.md).
