# 1. Hardware

Three small nodes in the end; two today.

| Node | Model | CPU | RAM (max) | Storage | Network | Status |
|---|---|---|---|---|---|---|
| `pve1` | Beelink Mini S12 Pro | Intel N100, 4C/4T | 16 GB DDR4-3200, 1 SO-DIMM (16 GB max) | M.2 2280 NVMe/SATA (PCIe Gen3 x1, 2 TB max) + one 2.5" SATA bay | 1 × 1 GbE | in service |
| `pve2` | Beelink Mini S12 Pro | Intel N100, 4C/4T | same | same | same | in service |
| `pve3` | Beelink Mini S13 Pro | Intel N150, 4C/4T | verify on arrival | verify on arrival | verify on arrival | future |

### Around the cluster

| Machine | Role | Specs |
|---|---|---|
| Synology DS224+ (`192.168.1.219`) | NFS storage, backups ([09](09-nas-and-control-node.md)) | Intel Celeron J4125 4C/4T; 2 GB RAM, 6 GB max (one slot, Synology modules only); 2 bays; 2 × 1 GbE; no M.2. From the [Product Specifications](https://global.synologydownload.com/download/Document/Hardware/ProductSpec/DiskStation/24-year/DS224%2B/enu/Product_Spec_DS224%2B_enu.pdf), Aug 2026 |
| Mac mini (M4, 16 GB) | Control node, QDevice host ([09](09-nas-and-control-node.md)) | Apple silicon (ARM), so not a cluster node |

## What the sources say

**Beelink Mini S12 Pro.** Beelink's product page is offline, so this comes from the
[archived product page](https://web.archive.org/web/20251212134538/https://www.bee-link.com/products/beelink-mini-s12-pro-n100)
and Beelink staff posts on the official forum:

- **CPU:** Intel N100, 4 cores / 4 threads.
- **Memory:** one DDR4-3200 SO-DIMM, 16 GB maximum. Beelink staff:
  "only support MAX 16GB" ([bbs.bee-link.com/d/3061](https://bbs.bee-link.com/d/3061)).
- **Storage:** M.2 2280 NVMe or SATA. Staff describe it as PCIe Gen3 ×1, up to 2 TB
  ([d/11081](https://bbs.bee-link.com/d/11081)). There is also a 2.5" SATA bay
  ([d/621](https://bbs.bee-link.com/d/621)).
- **Network:** one 1000 Mbps port. The page states no chipset. Users report a Realtek
  RTL8111/8168, which Linux drives with `r8169`.
- **Wi-Fi:** Intel AX101. Proxmox doesn't use it.
- **Firmware:** UEFI only. Staff say there is no Legacy mode.

**Intel N100 / N150.** These figures are from Intel ARK
([N100](https://www.intel.com/content/www/us/en/products/sku/231803/intel-processor-n100-6m-cache-up-to-3-40-ghz/specifications.html),
[N150](https://www.intel.com/content/www/us/en/products/sku/241636/intel-processor-n150-6m-cache-up-to-3-60-ghz/specifications.html)):

- 4C/4T.
- **16 GB maximum memory**, single channel.
- VT-x, VT-d and EPT supported.
- AVX2 supported.

Intel lists the same instruction-set extensions for both chips. OpenTofu gives every VM
one common CPU type (`x86-64-v2-AES`) instead of `host`, so VMs can keep moving between
nodes when the N150 joins.

**Beelink Mini S13 Pro: not verified.** Beelink publishes no "S13 Pro" spec page, only a
"Mini S13". Retail listings disagree with each other, for example on 1 GbE versus 2.5 GbE.
Fill in the `pve3` row from the unit itself when it arrives (`lscpu`, `free -g`,
`lsblk`, `ethtool <nic>`). Treat its RAM ceiling as 16 GB until the hardware proves
otherwise.

## Capacity plan: 16 GB per node, by design

The limit is 16 GB per node, from Beelink and Intel alike, so the lab is sized to fit it.
Upgrading RAM is not a plan.

| Per node (estimates) | Approx. |
|---|---|
| Proxmox VE + services | ~1–1.5 GB |
| ZFS ARC (capped by Ansible) | 2 GB |
| Left for guests | ~12–13 GB |

Today that is about 25 GB for guests across two nodes. With `pve3` it becomes about
37 GB. The gateway takes 256 MB. Size the WALLIX lab's guests in `config/lab.yml` against this
budget; Windows Server guests are the expensive part.

## BIOS settings (S12 Pro)

The steps are from Beelink's own guides, linked by its staff:

1. **Enter setup:** press `Del` repeatedly at power-on ([d/7790](https://bbs.bee-link.com/d/7790)).
   `F4` saves. For the boot menu, staff use `F7` on other models, but that is
   unconfirmed for the S12 Pro.
2. **Power on after an outage:** *Chipset → PCH-IO Configuration → State After G3 →
   S0 State* ([Beelink tutorial](https://buildin.ai/lizong/share/59bf79eb-6be3-4875-88f8-ae1c63e78467),
   [d/2923](https://bbs.bee-link.com/d/2923)). The only choices are S0 and S5; there is
   no "last state". Some users on BIOS `ADLNV105` report the option is missing.
3. **Wake-on-LAN** is enabled by default in the BIOS, per staff
   ([d/3766](https://bbs.bee-link.com/d/3766)).
4. **Virtualization:** VT-x and VT-d. Check that they are enabled; Proxmox needs VT-x.

Together, settings 2 and 3 are this lab's out-of-band management. The mini PCs have no
IPMI. A node comes back by itself after a power cut, and a node that is shut down can
be woken from the LAN (see `docs/07-remote-management.md`).

## Optional later

- A second disk in the 2.5" bay, for backups (`vzdump`) or ISO storage.
- A USB 2.5 GbE adapter per node, for a dedicated cluster/migration link.
  This is not needed for the lab as declared.
