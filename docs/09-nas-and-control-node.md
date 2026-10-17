# 9. The NAS and the control node

Two always-on machines next to the cluster, each with one job:

| Machine | Role | Why it is a good fit |
|---|---|---|
| **Synology DS224+** | NFS storage for backups, ISOs, templates and disk images, and the third quorum vote (QDevice) | Always on, outside the cluster, with disks meant for data |
| **Mac mini (M4, 16 GB)** | Control node: runs `make`, keeps the OpenTofu state and the API token | Always on at home; the laptop drives it from anywhere over Tailscale |

The laptop stays a client. It can run everything too, but state and secrets have one
home: the Mac mini.

## The DS224+ as NFS storage

`terraform/nas.tf` adds the NAS to every node as NFS storage `nas`, with content
`backup`, `iso`, `vztmpl` and `import`. It also creates one weekly backup job per pool in
`nas.backup.pools` (Saturday 03:00, snapshot mode, zstd, keep 3 + 4 weekly). It stays off
until the share exists:

1. On the NAS, create a shared folder (e.g. `proxmox`). Enable NFS, and give the folder an
   NFS permission rule for each node's address with read/write access. Use Synology's NFS
   documentation for the DSM screens.
2. In `config/lab.yml`, set `nas.export` to the NFS path DSM shows for the folder, and
   `nas.options` to an NFS version your DSM has enabled. Both are marked `verify`.
3. Put the NAS address in `ansible/inventory/hosts.yml` (host `ds224`).
4. Set `nas.enabled: true`, then `make plan` and `make apply`.

Backups land on the NAS, so restoring a guest no longer depends on its node's own disk
surviving.

## The third quorum vote (QDevice)

Two nodes need a third vote ([04-cluster.md](04-cluster.md#the-two-node-quorum-problem)).
The vote comes from a small Debian host outside the cluster running `corosync-qnetd`.
Candidates, in order of preference:

- a Debian VM or container **on the NAS**. Check that the DS224+ supports Synology's
  virtualization or container package, and that it has the RAM to spare;
- a Linux VM on the Mac mini.

The Proxmox steps are the same either way:

```sh
apt install corosync-qnetd               # on the QDevice host
apt install corosync-qdevice             # on every Proxmox node
pvecm qdevice setup <QDEVICE-IP>         # on one node
```

When pve3 joins, remove it with `pvecm qdevice remove`: Proxmox discourages QDevices for
odd node counts.

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
brew install ansible opentofu jq shellcheck yamllint
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
ssh macmini 'cd ~/code/Lab && make lab LAB=pam CMD=status'
```

Or run `make lab` on the laptop directly, with a copy of the token. `lab-ctl.sh` only
needs the token and the API endpoint, not the state.

### What the Mac mini is not

The cluster is x86 (N100/N150) and the Mac mini is Apple silicon (ARM), so the lab's x86
VMs could never move to it. It stays the control node, not a fourth node.
