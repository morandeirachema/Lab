# 6. The WALLIX lab

The first lab is a **WALLIX PAM lab**, built from the WALLIX VirtualBox OVAs, for the
WALLIX certification track. The `Cyber-Career` plan records WCP-P as held and WCE-P
(WALLIX Certified Expert) as expected before November 2026.

| | |
|---|---|
| Lab / pool | `wallix`: `make lab LAB=wallix …` |
| Segment | `pam`, `10.10.10.0/24`. No internet; only your LAN reaches it, through `labgw` |
| VMIDs | 1000–1999. VMID order is boot order |
| Guests | one entry per OVA in `config/lab.yml` → `labs.wallix.vms` (empty until step 2) |

## WALLIX's own requirements

Checked against WALLIX's public documents (October 2026). The 12.x Deployment Guide is
behind a WALLIX login, so some figures come from the newest public guide, **10.0.6**, and
are marked as such.

| Topic | What WALLIX says | Source |
|---|---|---|
| Hypervisors | vSphere, Nutanix AHV, **KVM**, Hyper-V. Proxmox and VirtualBox are not listed; Proxmox runs KVM | [PAM datasheet 2025](https://www.wallix.com/wp-content/uploads/2024/09/DATASHEET_2025_WALLIX_PAM_EN.pdf) |
| Images | ISO, VMware OVA, Hyper-V VHDX, and a **KVM `.qcow2`** (support portal downloads) | [Bastion Quick Start 10.0.6](https://marketplace-wallix.s3.amazonaws.com/Bastion-quickstart-en.pdf) |
| Bastion sizing | "2 CPUs, 4GB of RAM and 50GB HHD" (10.0.6) | Quick Start 10.0.6 |
| Access Manager | a separate appliance; 5.2.4.0 "requires a minimum of 4GB RAM and 50GB disk space" | [AM release notes](https://pam.wallix.one/documentation/release-notes/am-rn-en.html) |
| First boot | 10.0.6: static factory address `192.168.10.5`, gateway `192.168.10.1`. 12.x has a console setup wizard with a network form | Quick Start 10.0.6; 12.x release notes |
| Accounts | default system and web admin accounts exist; their passwords "must be immediately changed on first connection" | Quick Start 10.0.6 |
| Ports | web UI 443, admin SSH 2242, SSH proxy 22, RDP/VNC proxy 3389, SNMP 161 | Quick Start 10.0.6; 12.3.2 Admin Guide |
| License | a license key from WALLIX Support is required. The 12.0.1 notes remove a default evaluation license "for Cloud installations"; on-premise eval terms aren't published | Quick Start 10.0.6; 12.0.1 release notes |
| WCE-P course lab | "5 Preconfigured virtual machines: Domain Controller (Windows 2016), Windows Server 2016, Linux Server, 2 WALLIX Bastion"; e-learning as OVA; host minimum "32GB RAM or more" | [WALLIX training catalog 2025–2026](https://www.wallix.com/wp-content/uploads/2024/04/WALLIX_TRAINING_2025-2026_ENG.pdf) |

> [!CAUTION]
> WALLIX advisory **WSA-2026-07-0001** (20 Jul 2026, CVSS 10) affects Bastion **12.3 before
> 12.3.7 and 12.4.0**; "Version 12.3.7 / Version 12.4.1 and higher: Patched"
> ([WALLIX alerts](https://www.wallix.com/support-services/alerts/)). Use a patched build if
> you can. Either way, the `pam` segment has no internet, and only your LAN reaches it.

**What this means here:**

- **Budget.** WALLIX's own course lab wants a 32 GB host. This cluster has about 25 GB for
  guests across two nodes. Two Bastions take 8 GB by WALLIX's sizing. The domain controller,
  the Windows Server and the Linux server have to fit in what's left. Their sizes in the
  course OVAs are what `make unpack` reports; split the five guests across `pve1` and `pve2`.
- **Bastion image.** If you have WALLIX support access, the **KVM `.qcow2`** is the image made
  for this hypervisor. Proxmox imports `.qcow2` directly: put it under `artifacts/`, point the
  entry's `image:` at it, and set `size_gb` to at least its virtual size (`qemu-img info`
  shows it). The course **OVAs** go through `make unpack` as usual.
- **Addresses.** A Bastion at its factory address `192.168.10.5` is outside the `pam` subnet
  (`10.10.10.0/24`). Either set a static `10.10.10.x` address, outside the DHCP range
  `.100–.199`, with gateway `10.10.10.1`, in its first-boot wizard; or move the segment to the
  course subnet (step 2, *fixed IP addresses*).
- **Reaching it from the Mac** (through `labgw`): `https://<bastion>` for the web UI,
  `ssh -p 2242` for administration, and ports 22 and 3389 for the proxied sessions.

## 1. Unpack each OVA

```sh
make unpack OVA=~/path/to/<appliance>.ova
```

For each OVA this:

- extracts it into `artifacts/ova/<name>/` (git-ignored);
- checks every file against the OVA's manifest, and refuses a corrupt or modified OVA;
- prints a `config/lab.yml` entry with the vCPU, memory and firmware from its OVF, the MAC
  VirtualBox recorded, and each disk's real capacity.

## 2. Declare the lab

Paste each entry under `labs.wallix.vms`. Then fill in:

- **`vmid`**: in boot order. Infrastructure the others depend on (e.g. a domain controller)
  first, the WALLIX appliances next, targets last.
- **`node`**: spread the guests across `pve1` and `pve2` within the
  [16 GB-per-node budget](01-hardware.md#capacity-plan-16-gb-per-node-by-design). Windows
  guests are the expensive ones.
- **`vnet: pam`**.
- **`os`**: `l26` for Linux appliances; `win10` (Windows 10 / Server 2016–2022) or `win11`
  (11 / Server 2025) for Windows. Add `tpm: true` if a Windows guest needs it.

Keep the defaults `bus: sata` and `nic: e1000`. Those are the hardware VirtualBox guests
already have drivers for.

**If the OVAs come with fixed IP addresses** (training labs often do), the lab segment has
to match them. Set `gateway.nets[0].address` to a free address in their subnet, adjust or
remove the `dhcp` range, and route that subnet from the Mac
([02-network.md](02-network.md#reaching-the-lab-from-the-mac)). Guests with a static IP but
no default route also need `gateway.snat_from_lan: true`.

## 3. Build it

```sh
make plan       # SDN, pools, gateway, one disk upload per disk, one VM per entry
make apply
make gateway    # DHCP/DNS for the pam segment and the routing policy
make lab LAB=wallix CMD=start
```

Open each guest's console in the Proxmox web UI for its first boot. An imported Windows
guest can treat the Proxmox NIC as new hardware, so check its network settings there.

## 4. Baseline and reset

Once everything works the way the exercises start:

```sh
make lab LAB=wallix CMD=stop
make lab LAB=wallix CMD=snapshot NAME=baseline
```

Reset after an exercise:

```sh
make lab LAB=wallix CMD=rollback NAME=baseline
```

On ZFS, Proxmox only rolls back to a guest's **most recent** snapshot ("can't rollback, 'X'
is not most recent snapshot"). Keep `baseline` the newest snapshot, or delete newer ones
first (`make lab LAB=wallix CMD=snapshots` lists them). The NAS also backs up the `wallix`
pool every week once `nas.enabled` is on ([09](09-nas-and-control-node.md)).

## If a guest doesn't boot

Check these first, in its `config/lab.yml` entry:

- **`firmware`**: `make unpack` reads it from the OVF.
- **`bus`**: `sata` is the default; `scsi` and `virtio` need drivers in the guest.
- **`size_gb`**: at least the capacity `make unpack` reported. Proxmox can grow a disk but
  not shrink it.
