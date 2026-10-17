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

> [!NOTE]
> Being verified against WALLIX's documentation: supported hypervisors, appliance sizing,
> and first-boot network setup. This section will cite those sources. Until then, use the
> values `make unpack` reads from each OVA. Those come from the OVA itself, not from a guess.

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
