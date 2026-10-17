# 9. The NAS and the control node

Two always-on machines next to the cluster, each with one job:

| Machine | Role | Why it is a good fit |
|---|---|---|
| **Synology DS224+** (`192.168.1.219`) | NFS storage for backups, ISOs and templates | Always on, outside the cluster, with disks meant for data |
| **Mac mini (M4, 16 GB)** | Control node: runs `make`, keeps the OpenTofu state and the API token; hosts the QDevice VM | Always on at home; the laptop drives it from anywhere over Tailscale |

The laptop stays a client. It can run everything too, but state and secrets have one
home: the Mac mini.

## The DS224+ as NFS storage

`terraform/nas.tf` adds the NAS to every node as NFS storage `nas`, with content `backup`,
`iso` and `vztmpl`. It also creates one weekly backup job per pool listed in
`nas.backup.pools`: Saturday 03:00, snapshot mode, zstd, keeping the last 3 plus 4 weekly.
It stays off until the NAS has a volume, a shared folder and an NFS rule.

**The NAS (verified).** From Synology's
[DS224+ Product Specifications](https://global.synologydownload.com/download/Document/Hardware/ProductSpec/DiskStation/24-year/DS224%2B/enu/Product_Spec_DS224%2B_enu.pdf),
updated Aug 6, 2026:

- 2 drive bays.
- RAID types: SHR, Basic, JBOD, RAID 0, RAID 1. File systems: Btrfs, ext4.
- 2 × 1 GbE, MTU 1,500 bytes.
- NFSv3, NFSv4 and NFSv4.1.
- 2 GB RAM, 6 GB maximum (one SO-DIMM slot, Synology modules only).
- Current DSM: 7.4.

DSM screens move between releases. Each step below links the Synology help page it comes from.

### 1. Use the existing volume; don't create a new pool

The NAS already runs **Pi-hole**, so it already has a storage pool and a volume. Containers
live on one. **Don't create, remove or rebuild a storage pool.** Synology warns that
creating one deletes all data on the drives it uses, and removing one deletes "its volumes
and all shared folders and packages on the volumes", Pi-hole included.

Check what's there in **Storage Manager → Storage**:

- **A pool across both drives (SHR or RAID 1):** nothing to do. Go to step 2.
- **A Basic pool on one drive, with the second bay empty:** that pool doesn't survive a
  drive failure, and the NAS will hold backups. Synology can convert it without losing data
  ([Change the RAID Type of a Storage Pool](https://kb.synology.com/en-global/DSM/help/DSM/StorageManager/storage_pool_change_raid_type?version=7)).
  Basic → RAID 1 needs one more drive, at least as large as the current one. With the pool
  *Healthy*, open the pool's menu → **Change RAID Type** → RAID 1, select the new drive,
  then **Apply**. The pool shows *Changing RAID type* until it's done.

The volume's file system is fixed, and Btrfs or ext4 both work for NFS.

### 2. Create the shared folder

([Create a Shared Folder](https://kb.synology.com/en-global/DSM/help/DSM/AdminCenter/file_share_create?version=7))

1. **Control Panel → Shared Folder → Create → Create Shared Folder**.
2. Name `proxmox`. For Location, choose the existing volume.
3. **Leave "Enable Recycle Bin" off** for this folder. Deleted files go to `#recycle`, so
   every backup Proxmox prunes would pile up there.
4. Finish the wizard. Skip user permissions: the nodes reach this folder by NFS, not as DSM users.

### 3. Turn on NFS

([NFS](https://kb.synology.com/en-global/DSM/help/DSM/AdminCenter/file_winmacnfs_nfs?version=7))

**Control Panel → File Services → NFS**: tick **Enable NFS service**, and set
**Maximum NFS protocol** to **NFSv4.1**. That matches `nas.options: vers=4.1` in
`config/lab.yml`.

### 4. Let the nodes in

([NFS Permissions](https://kb.synology.com/en-global/DSM/help/DSM/AdminCenter/file_share_privilege_nfs?version=7))

**Control Panel → Shared Folder →** select `proxmox` **→ Edit → NFS Permissions → Create**.
Create one rule per node: `192.168.1.11`, `192.168.1.12`, and `192.168.1.13` when pve3 joins.

| Field | Value | Why |
|---|---|---|
| Hostname or IP | the node's address | Only the cluster nodes mount it |
| Privilege | Read/Write | Proxmox writes backups and templates |
| Squash | **No mapping** | Proxmox mounts as root; root's files stay root's |
| Security | AUTH_SYS | Plain NFS on the home LAN |
| Enable asynchronous, Allow connections from non-privileged ports, Allow users to access mounted subfolders | leave as they are | Not needed for this use |

If the DSM firewall is on, allow the nodes for the NFS file service as well. Synology lists
it as "Mac/Linux file server".

### 5. Lab names through Pi-hole

Pi-hole is the LAN's DNS (`lan.dns` in `config/lab.yml`). One conditional-forwarding entry
sends lab names, and reverse lookups for the lab subnet, to the lab gateway. Every device
on the LAN then resolves `<guest>.lab.home.arpa` names, with no `/etc/resolver` file on each
Mac. Pi-hole v6 calls the setting `dns.revServers`. Its
[documented format](https://docs.pi-hole.net/ftldns/configfile/) is
`"<enabled>,<ip-address>/<prefix-len>,<server>[#<port>][,<domain>]"`:

```sh
# run inside the Pi-hole container
pihole-FTL --config dns.revServers '[ "true,10.10.10.0/24,192.168.1.20,lab.home.arpa" ]'
```

Or set it in the container's environment, the form the Pi-hole docs give for Docker
Compose:

```yaml
environment:
  FTLCONF_dns_revServers: "true,10.10.10.0/24,192.168.1.20,lab.home.arpa"
```

The value replaces the whole list. If you already have an entry (for the router, say),
include it in the same array. There's no loop: the gateway answers `lab.home.arpa` and
private reverse lookups itself (`local=/lab.home.arpa/`, `bogus-priv`), and forwards only
other names to Pi-hole.

The NAS now also carries the LAN's DNS. Give each Proxmox node a second DNS server (the
router), so `apt` still resolves while the NAS restarts for a DSM update.

### 6. Point the code at it

From any node, list what the NAS exports. The Proxmox docs give the export "as listed by
`pvesm nfsscan`":

```sh
ssh pve1 pvesm nfsscan 192.168.1.219
```

Put that path, normally `/volume1/proxmox`, in `nas.export` in `config/lab.yml`, set
`nas.enabled: true`, then:

```sh
make plan    # + proxmox_storage_nfs.nas, + proxmox_backup_job.lab["wallix"] and ["infra"]
make apply
```

Every node then shows the `nas` storage. The `wallix` pool (the lab) and the `infra` pool (`labgw`,
`obs`) are backed up every Saturday.

## The third quorum vote (QDevice)

Two nodes need a third vote ([04-cluster.md](04-cluster.md#the-two-node-quorum-problem)).
The vote comes from a small Linux host outside the cluster running `corosync-qnetd`. The
Proxmox docs ask only for network access to the cluster, the `corosync-qnetd` package,
TCP port 5403 reachable, and root SSH during setup. It "isn't limited to the low latencies
requirements of corosync".

Where to run it:

- **The Mac mini, in a small Linux VM: the practical default.**
- **The NAS, only after a RAM upgrade.** Synology says virtual machines "can run only on
  Synology NAS devices with more than 2 GB of memory". The DS224+ ships with exactly 2 GB, so
  it needs the 4 GB module (6 GB total). Synology's list of supported Linux guests also stops
  at Debian 11; newer versions are "at your own discretion". Container Manager is supported on
  the DS224+, but neither Synology nor Proxmox documents `corosync-qnetd` in a container
  there.

The Proxmox steps are the same wherever it runs:

```sh
apt install corosync-qnetd               # on the QDevice host
apt install corosync-qdevice             # on every Proxmox node
pvecm qdevice setup <QDEVICE-IP>         # on one node; needs root SSH to the QDevice host
```

When pve3 joins, remove it with `pvecm qdevice remove`: Proxmox discourages QDevices for odd
node counts.

## The Mac mini as control node

### Keep it on

`pmset` (see `man pmset`) sets the power behaviour. `pmset -g cap` lists what this Mac
supports.

```sh
sudo pmset -a sleep 0          # never sleep
sudo pmset -a autorestart 1    # restart after a power loss
sudo pmset -a womp 1           # wake on Ethernet magic packet
```

Turn on *Remote Login* in System Settings → General → Sharing, so the laptop can SSH in.
Install Tailscale on the Mac mini too, so that works from outside home.

### Tools and repo

Install the same tools as in [03-install.md](03-install.md#on-the-mac-once):

```sh
brew install ansible ansible-lint opentofu jq shellcheck yamllint
git clone https://github.com/morandeirachema/Lab.git ~/code/Lab && cd ~/code/Lab
ssh-keygen -t ed25519                    # the control node's own key
ssh-copy-id root@192.168.1.11            # … and every other node
```

Run `make iac` **from the Mac mini**, so the API token file is created there
(`~/.config/lab/proxmox-api-token`). Run `make apply` from there too, so
`terraform/terraform.tfstate` lives there. Keep that file in a backup you already use,
for example a Time Machine destination on the NAS if you set one up.

### From the laptop

```sh
ssh macmini 'cd ~/code/Lab && make lab LAB=wallix CMD=status'
```

Or run `make lab` on the laptop directly, with a copy of the token. `lab-ctl.sh` only
needs the token and the API endpoint, not the state.

### What the Mac mini is not

The cluster is x86 (N100/N150) and the Mac mini is Apple silicon (ARM), so the lab's x86
VMs could never move to it. It stays the control node, not a fourth node.
