# 11. Cyber range (CEH practice)

The range is a set of guests on the `cyber` segment (`10.10.30.0/24`, VLAN tag 30): an
attacker VM from Kali's prebuilt image, plus intentionally vulnerable targets. It
supports study for **CEH v13**, which the `Cyber-Career` plan sits in April 2027. That
exam is knowledge-based: 125 multiple-choice questions in 4 hours, per that plan's
reference table (sourced from eccouncil.org). EC-Council's own course labs are the official
practice environment. This range is somewhere to practise its topics on machines you own.

Everything is declared in `config/lab.yml`: the `cyber` entry in `gateway.nets` and
`labs.cyber.vms`.

## What can talk to what

`cyber` is an **isolated** gateway net ([02](02-network.md#the-gateways-policy)). `labgw`
has a leg on it only to hand out DHCP leases.

| From → to | Verdict |
|---|---|
| range guest ↔ range guest | allowed: one layer-2 segment, across both nodes |
| range guest → `labgw` | a DHCP lease only: no DNS, no ping, no SSH |
| range guest → LAN, internet, other lab nets | dropped; the lease has no router, and `labgw` forwards nothing |
| LAN or Mac → range guest | dropped; use the Proxmox console |
| range guest → `obs` | only with `collector: true` on the net (off by default) |

Every lab VM has a single NIC (`terraform/vms.tf` declares one `network_device`), so no
guest can bridge the range to another vnet. Keep it that way. A dual-homed "jump" VM
would route around `labgw`'s policy, so this lab doesn't use one.

With `sdn.type: vlan`, isolation also depends on the switch: it must carry tag 30 between
the nodes and have no IP interface on that VLAN.

## Rules of engagement

- **Scope is the range.** Point tools only at guests on `cyber`. The home LAN, the
  internet, the NAS, the Proxmox nodes and the other labs are out of scope, even when
  they are yours. CEH's first module, *Introduction to Ethical Hacking*, covers why
  scope and authorisation come first.
- **Treat target images as untrusted.** Vulnerable VMs are built by third parties to be
  broken. That is why they live only on `cyber`. Never move one to another vnet, and
  leave `collector: false` unless an exercise needs the logs.
- **No load tests.** The range shares CPU, RAM and disk with the WALLIX lab, `labgw` and
  `obs`. Flooding a target loads the node, and everything on it with it. Study
  *Denial-of-Service* from the course material.
- **Reset after every exercise.** Roll back to the `clean` snapshot (below). A target you
  have broken stays broken until you do.

## Build it

1. **The attacker VM.** On the Mac:
   ```sh
   brew install gnupg sevenzip   # once
   make kali                     # or: make kali RELEASE=2026.2
   ```
   `scripts/kali-fetch.sh` checks the release's `SHA256SUMS` against its signature by
   Kali's key (`827C 8569 F251 8CC6 77FE CA1A ED65 462E C8D5 E4C5`, from
   [Kali's download docs](https://www.kali.org/docs/introduction/download-official-kali-linux-images/)).
   It then downloads the QEMU image (3.6 GiB) and checks it, extracts the `.qcow2` (about 16 GB)
   into `artifacts/kali/`, and prints the entry for `labs.cyber.vms`. For 2026.2 the disk's
   virtual size is 86,000,000,000 bytes, which gives `size_gb: 81`. The
   [kali-vm README](https://gitlab.com/kalilinux/build-scripts/kali-vm) is the source for
   the entry's settings: "The image is MBR with `grub-pc`, so the default firmware (SeaBIOS)
   boots it", the QEMU variant has the "QEMU and SPICE guest agents pre-installed", and its
   example attaches the disk as virtio.
2. **Targets.** Each comes with its own download and terms, so getting them stays
   manual. Then:
   - **OVAs:** `make unpack OVA=…`, the same path as the WALLIX guests
     ([06](06-wallix-lab.md)). Set `vnet: cyber`.
   - **Metasploitable 2**, "an intentionally vulnerable Ubuntu Linux virtual machine that
     is designed for testing common vulnerabilities"
     ([Rapid7](https://docs.rapid7.com/metasploit/metasploitable-2/), which links the
     download on SourceForge). Declare its disk directly. Import takes `.vmdk`, `.qcow2`
     and `.raw` (lower-case extensions), and `size_gb` must be at least the disk's capacity.
   - **[VulnHub](https://www.vulnhub.com/)** catalogues many more. The format varies by
     machine, so check each download.

   Use VMIDs 3000–3999 and `node: pve2`. `pve1` already runs `labgw` and `obs`.
3. **Apply, then start.**
   ```sh
   make apply                      # uploads the disks and creates the VMs, stopped
   make lab LAB=cyber CMD=start
   ```
4. **First boot, from the Proxmox console** (the VM's *Console* tab; the range has no
   path from the Mac). Kali's documented default login for its prebuilt images is
   `kali` / `kali`, so change it first (`passwd`). Then check the isolation (next section).
5. **Snapshot the clean state** with the lab stopped:
   ```sh
   make lab LAB=cyber CMD=stop
   make lab LAB=cyber CMD=snapshot NAME=clean
   make lab LAB=cyber CMD=rollback NAME=clean   # after every exercise
   ```
   On ZFS, Proxmox only rolls back to a guest's most recent snapshot, so keep `clean` the
   newest ([06](06-wallix-lab.md)).

**Memory.** The QEMU guide on kali.org sizes its example VM at 2 GB and 2 cores, which
`make kali` copies. Add each target's own figure and check the total against `pve2`'s
budget ([01](01-hardware.md#capacity-plan-16-gb-per-node-by-design)). If it doesn't fit,
run one lab at a time: `make lab LAB=wallix CMD=stop` before you start the range.

## Check the isolation first

Before the first exercise, prove the controls from inside, on Kali's console. This is
also the [CISSP projects](12-cissp-projects.md)' security-assessment exercise.

```sh
ip -4 addr show; ip route        # a 10.10.30.x lease, and no default route
cat /etc/resolv.conf             # no DNS server came with the lease
sudo ip route add default via 10.10.30.1
ping -c2 -W2 10.10.30.1          # no reply: labgw answers DHCP and nothing else
ping -c2 -W2 192.168.1.1         # no reply: nothing is forwarded to the LAN
ping -c2 -W2 1.1.1.1             # no reply: nor to the internet
sudo ip route del default via 10.10.30.1
```

Run the last three `ping`s with the route in place. It shows that `labgw` drops the
traffic, and not merely that the guest has no route. If any of them gets a reply, stop and
check `labgw`'s ruleset (`nft list ruleset`) before going further.

## CEH v13 modules and this lab

EC-Council lists 20 modules for the course
([eccouncil.org](https://www.eccouncil.org/train-certify/certified-ethical-hacker-ceh/)).
This table shows where each can be practised. *Range* means against your own targets on
`cyber`.

| # | Module | Where to practise |
|---|---|---|
| 1 | Introduction to Ethical Hacking | the rules of engagement above |
| 2 | Footprinting and Reconnaissance | course labs: much of it is about public sources, and the range has no internet |
| 3 | Scanning Networks | range |
| 4 | Enumeration | range |
| 5 | Vulnerability Analysis | range |
| 6 | System Hacking | range |
| 7 | Malware Threats | course labs: no live malware on hardware that shares a network with your home |
| 8 | Sniffing | range: traffic between range guests |
| 9 | Social Engineering | course material: people, not machines |
| 10 | Denial-of-Service | course labs: shared hardware (rules of engagement) |
| 11 | Session Hijacking | range, with web targets |
| 12 | Evading IDS, Firewalls, and Honeypots | partly: `labgw`'s nftables is a firewall, but the range has no IDS yet |
| 13 | Hacking Web Servers | range |
| 14 | Hacking Web Applications | range |
| 15 | SQL Injection | range |
| 16 | Hacking Wireless Networks | course labs: no wireless in the lab |
| 17 | Hacking Mobile Platforms | course labs |
| 18 | IoT and OT Hacking | course labs |
| 19 | Cloud Computing | course labs; the planned DevOps lab covers containers ([08](08-roadmap.md)) |
| 20 | Cryptography | anywhere, offline |

## The blue side

To see the range from the defender's chair, set `collector: true` on the `cyber` net
and run `make gateway`. Then point a target's syslog at `10.10.40.10:514`
([10](10-observability.md)). Its logs land in Loki next to WALLIX's, and the
[CISSP security-operations project](12-cissp-projects.md) uses them. The trade-off: every
range guest can then reach Alloy's two ports on `obs`. Turn it off again when the exercise
is done.

## Take it down

Remove the entries from `labs.cyber.vms` and run `make apply`. OpenTofu deletes the VMs
and the disk images it uploaded. The images stay in `artifacts/` on the Mac until you delete
them.
