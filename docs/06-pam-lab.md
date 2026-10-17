# 6. The PAM lab

Phase 1 runs the **PAMv1 appliance** (your `PAMv1` repository, `deploy/ova/`) on the
isolated `pam` segment. The appliance facts below come from PAMv1's
`deploy/ova/README.md`.

| Guest | VMID | Node | vCPU / RAM | Disk | Network |
|---|---|---|---|---|---|
| `pamv1`: Debian 13, PostgreSQL, `pam-server` | 1001 | pve1 | 2 / 2048 MiB (as its OVF declares) | 20 GiB, SATA | `pam`, e1000, DHCP |
| `labgw`: lab gateway | 110 | pve1 | 1 / 256 MiB | 2 GiB | LAN + `pam` |

## 1. Build and check the OVA (in the PAMv1 repo)

```sh
cd ~/code/PAMv1/deploy/ova && ./build.sh
# → ~/.cache/pamv1-ova/pamv1-appliance-13.6.0.ova (+ .sha256)
cd ~/.cache/pamv1-ova && shasum -a 256 -c pamv1-appliance-13.6.0.ova.sha256
```

The `13.6.0` in the file name is the Debian release the build installs
(`DEBIAN_VERSION`). The build needs QEMU, `xorriso`, `curl`, `tar` and Go 1.26+. According to its README it
takes 10–20 minutes with KVM and "considerably longer without", which includes a Mac.

## 2. Unpack it for import (in this repo)

```sh
make unpack OVA=~/.cache/pamv1-ova/pamv1-appliance-13.6.0.ova
```

This extracts the OVA into `artifacts/ova/pamv1-appliance-13.6.0/`, checks the OVA's
SHA-256 manifest, and prints the `config/lab.yml` entry. The `pamv1` entry is already
in `config/lab.yml`. Compare its `size_gb` with the capacity reported, and raise it if
the image is bigger: Proxmox can grow a disk but not shrink it. For a new version of the
OVA, update the `image:` path.

## 3. Build the lab

```sh
make plan       # expect: SDN, pools, template, gateway, 1 disk upload, VM 1001
make apply
make gateway    # DHCP for the pam segment, routing policy
```

## 4. First boot

```sh
make lab LAB=pam CMD=start
```

On first boot the appliance generates its own vault master key, admin API key,
PostgreSQL password and SSH host keys. Nothing secret is baked into the OVA. It prints
the **admin key** to the console. Open *VM 1001 → Console* in the Proxmox web UI to
read it. The key is also in `/root/pamv1-credentials.txt` inside the appliance.

The appliance's network config matches `en*`/`eth*` and asks for DHCP, so the e1000
NIC Proxmox gives it just works. It gets a lease from `labgw` in `10.10.10.100–199`.
If its DHCP client sends its hostname, it also appears in DNS as
`pamv1.lab.home.arpa`. If the name doesn't resolve, read the lease on the gateway:

```sh
ssh labgw cat /var/lib/misc/dnsmasq.leases
```

## 5. Use it from the Mac

Set up the route and resolver from [02-network.md](02-network.md#reaching-the-lab-from-the-mac) first.

| What | How (from the appliance README) |
|---|---|
| Portal / REST API | <http://pamv1.lab.home.arpa:8080>. Sign on with the admin key in the *access token* field, password blank |
| SSH session proxy | `ssh -p 2222 <credential-user>@<target>@pamv1.lab.home.arpa`, with the admin key as the password |
| Appliance shell | `ssh pam@pamv1.lab.home.arpa`. The placeholder password `pamv1` is force-expired; set a new one, then add a key |

The portal serves plain HTTP on 8080. The `pam` segment has no internet, and only your
LAN can reach it, through the gateway.

## 6. Baseline and reset

Once first boot is done and you have recorded the admin key:

```sh
make lab LAB=pam CMD=stop
make lab LAB=pam CMD=snapshot NAME=baseline
```

Reset after an exercise:

```sh
make lab LAB=pam CMD=rollback NAME=baseline
```

On ZFS, Proxmox only rolls back to a guest's **most recent** snapshot. Its storage code
refuses otherwise: "can't rollback, 'X' is not most recent snapshot". Keep `baseline`
as the newest snapshot, or delete newer ones first (`make lab LAB=pam CMD=snapshots`
lists them).

## What the appliance does not include (per its README)

- **Targets.** Add them as more entries under `labs.pam.vms`: a Linux SSH target, a
  Windows or xrdp RDP target. PAMv1's Docker demos include a throwaway xrdp target.
- **guacd.** The in-portal RDP and VNC viewers stay inactive until guacd is installed
  and `PAM_GUACD_ADDR` is set.
- **TLS** on the portal.

## First real import

PAMv1's README says that "the import path into VirtualBox, VMware or ESXi has not been
exercised"; Proxmox isn't on that list either. This lab is the first real import, so check carefully that it boots. If it doesn't, the first
things to change in its `config/lab.yml` entry are `bus` (`sata` is the default) and
`firmware`.

## Other OVAs

Any other appliance you have as a VirtualBox OVA follows the same path: a vendor PAM
trial image, a Windows domain controller for targets, a vulnerable VM for the cyber
range. Run `make unpack`, paste the printed entry under the right lab, then
`make apply`. Windows guests keep `bus: sata` and `nic: e1000`, the drivers VirtualBox
guests already have. Use `os: win10` or `win11`, and size their memory within the
[16 GB per node](01-hardware.md#capacity-plan-16-gb-per-node-by-design).
