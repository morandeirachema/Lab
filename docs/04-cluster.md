# 4. The cluster

Forming the cluster is a one-time, interactive step: `pvecm add` asks for the existing
node's root password. It stays manual on purpose. Everything after it is code.

**Join a node before it has any guests.** The Proxmox docs: "a joining node cannot hold
any guests, since guest IDs could otherwise conflict." So form the cluster before
`make apply`.

## Two nodes now

```sh
ssh pve1 pvecm create lab          # creates the cluster on pve1
ssh pve2 pvecm add 192.168.1.11    # run on pve2; asks for pve1's root password
ssh pve1 pvecm status              # both nodes listed, "Quorate: Yes"
```

### The two-node quorum problem

Each node has one vote, and the cluster needs a majority. With two nodes, losing either
one leaves the survivor without quorum. Its `/etc/pve` turns read-only and it will not
start guests. Two documented ways out:

- **QDevice (recommended for two nodes).** A third vote from a small always-on Linux
  machine outside the cluster: a Raspberry Pi, a NAS, a VM elsewhere. The Proxmox docs
  "support QDevices for clusters with an even number of nodes and recommend it for 2 node
  clusters."
  ```sh
  # on the external machine
  apt install corosync-qnetd
  # on every Proxmox node
  apt install corosync-qdevice
  # on one node
  pvecm qdevice setup <QDEVICE-IP>
  ```
- **Emergency only:** when you are certain the other node is down (not just
  unreachable), run on the survivor:
  ```sh
  pvecm expected 1
  ```
  This sets the expected votes to one, so the survivor is quorate again.

Corosync shares the single LAN port with everything else on these nodes. Proxmox
recommends a separate network for it. That's acceptable for a lab; the USB NIC in
[01-hardware.md](01-hardware.md#optional-later) is how you'd add a second link.

## Adding pve3 (the S13 Pro)

1. Install it as in [03-install.md](03-install.md), with the same filesystem as the others.
2. Add it under `proxmox` in `ansible/inventory/hosts.yml`, then baseline only it:
   ```sh
   cd ansible && ansible-playbook playbooks/pve-postinstall.yml --limit pve3
   ```
3. Join it: `ssh pve3 pvecm add 192.168.1.11`.
4. **Remove the QDevice if you had one.** With three nodes the count is odd, and "for
   clusters with an odd node count, we currently discourage the use of QDevices."
   ```sh
   pvecm qdevice remove
   ```
5. `make plan && make apply`. A `vlan` zone needs nothing new. A `vxlan` zone gets
   pve3's address as a new peer, because the peers come from the inventory.

Fill in pve3's row in [01-hardware.md](01-hardware.md) from the real unit. There is no
official spec sheet to copy from.
