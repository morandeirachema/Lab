<div align="center">

# 🧪 Lab

**A Proxmox VE homelab, declared as code, for PAM, DevOps and cybersecurity practice.**

Two Beelink Mini S12 Pro nodes now, a Beelink Mini S13 Pro later.
One YAML file describes the lab; OpenTofu and Ansible build it; `make` drives everything from a Mac.

[![check](https://github.com/morandeirachema/Lab/actions/workflows/check.yml/badge.svg)](https://github.com/morandeirachema/Lab/actions/workflows/check.yml)
![Proxmox VE 9](https://img.shields.io/badge/Proxmox_VE-9.x-E57000?logo=proxmox&logoColor=white)
![OpenTofu](https://img.shields.io/badge/OpenTofu-1.13-FFDA18?logo=opentofu&logoColor=black)
![bpg/proxmox](https://img.shields.io/badge/bpg%2Fproxmox-0.116-5C4EE5)
![Ansible](https://img.shields.io/badge/Ansible-roles-EE0000?logo=ansible&logoColor=white)

</div>

---

## ✨ Highlights

- **One source of truth.** [`config/lab.yml`](config/lab.yml) declares the segments, the gateway and every lab's VMs. [`ansible/inventory/hosts.yml`](ansible/inventory/hosts.yml) holds every address. OpenTofu and Ansible both read them, so nothing is written twice.
- **VirtualBox OVAs in, Proxmox VMs out.** `make unpack` verifies an OVA against its manifest and reads its OVF. Then OpenTofu uploads the disks and builds the VM: SATA disks and an e1000 NIC, the hardware VirtualBox guests already have drivers for.
- **Isolated lab segments across nodes.** An SDN zone (VLAN or VXLAN) with `pam`, `devops` and `cyber` vnets. A tiny gateway container gives them DHCP and DNS and enforces a firewall policy. `cyber` is never routed.
- **Remote by default.** `make lab` starts, stops, snapshots and rolls back whole labs over the Proxmox API. Tailscale reaches the nodes from anywhere without opening a port.
- **No secrets in git.** The API token lives in `~/.config/lab/` (0600). The Tailscale key is read from the environment. OVAs and disks are git-ignored.
- **Checked, not guessed.** Specs and commands come from Beelink, Intel, Proxmox, Tailscale and provider sources, linked in the docs. Anything unverified (like the S13 Pro's specs) is marked as unverified.
- **CI on every push.** shellcheck, yamllint, Ansible syntax, and `tofu validate` against the provider's real schema, all without touching the cluster.

## 🗺️ Architecture

```mermaid
flowchart TB
  subgraph mac["💻 Mac"]
    yml["config/lab.yml<br/>+ inventory"]
    tofu["OpenTofu<br/>bpg/proxmox"]
    ans["Ansible"]
    ctl["make lab<br/>(API)"]
    yml --> tofu
    yml --> ans
  end

  subgraph cluster["Proxmox VE 9 cluster"]
    pve1["pve1 · S12 Pro<br/>N100 · 16 GB"]
    pve2["pve2 · S12 Pro<br/>N100 · 16 GB"]
    pve3["pve3 · S13 Pro<br/>(later)"]
    subgraph sdn["SDN zone 'lab'"]
      pam["pam · 10.10.10.0/24"]
      devops["devops · 10.10.20.0/24"]
      cyber["cyber · never routed"]
    end
    labgw["labgw<br/>dnsmasq + nftables"]
    pamv1["pamv1<br/>PAMv1 appliance"]
    labgw --- pam --- pamv1
  end

  tofu -- "API token" --> cluster
  ctl -- "API token" --> cluster
  ans -- "SSH" --> pve1
  ans -- "SSH" --> pve2
  ans -- "SSH" --> labgw
  lan(("🏠 Home LAN")) --- pve1
  lan --- pve2
  lan --- labgw
  lan -.- pve3
```

| Layer | Tool | Owns |
|---|---|---|
| Declaration | YAML | the lab: segments, pools, gateway, guests, addresses |
| Nodes | Ansible `pve_base` | repos, upgrades, ZFS ARC, kernel modules, SSH, routes |
| Cluster prerequisites | Ansible `pve_iac` | `terraform@pve`, its role and API token, `import` storage |
| Proxmox objects | OpenTofu | SDN zone and vnets, pools, gateway container, disk uploads, VMs |
| Inside the gateway | Ansible `lab_gateway` | DHCP/DNS (dnsmasq), routing policy (nftables) |
| Remote access | Ansible `tailscale` | tailnet membership, subnet routes |
| Operations | `scripts/` | OVA unpacking, lab power and snapshots |

## 🚀 Quick start

```sh
brew install ansible opentofu jq shellcheck yamllint
make check                     # validate everything offline
```

Then, for a fresh cluster ([full walkthrough](docs/05-iac-workflow.md)):

```sh
make ping && make nodes        # baseline every node                (docs/03)
#   form the cluster by hand:  pvecm create / pvecm add             (docs/04)
make iac                       # API user, role, token → ~/.config/lab/
make unpack OVA=~/.cache/pamv1-ova/pamv1-appliance-13.6.0.ova      (docs/06)
make init && make plan         # read the plan
make apply                     # SDN, pools, gateway, PAM VM
make gateway                   # DHCP + firewall inside the gateway
make lab LAB=pam CMD=start
```

## 🎛️ Day to day

| You want to… | Run |
|---|---|
| See a lab | `make lab LAB=pam CMD=status` |
| Start / stop it (boot order = VMID order) | `make lab LAB=pam CMD=start` · `CMD=stop` |
| Save a clean state | `make lab LAB=pam CMD=snapshot NAME=baseline` |
| Reset after an exercise | `make lab LAB=pam CMD=rollback NAME=baseline` |
| Add a VM from an OVA | `make unpack OVA=…`, paste the entry into `config/lab.yml`, `make apply` |
| Change anything | edit `config/lab.yml`, then `make plan` and `make apply` |
| Reach it from outside home | `make remote` (Tailscale), see [docs/07](docs/07-remote-management.md) |

## 🧱 Hardware

| Node | Model | CPU | RAM | Network | Status |
|---|---|---|---|---|---|
| `pve1` | Beelink Mini S12 Pro | Intel N100 · 4C/4T | 16 GB (the maximum) | 1 × 1 GbE | ✅ in service |
| `pve2` | Beelink Mini S12 Pro | Intel N100 · 4C/4T | 16 GB (the maximum) | 1 × 1 GbE | ✅ in service |
| `pve3` | Beelink Mini S13 Pro | Intel N150 · 4C/4T | verify on arrival | verify on arrival | 🔜 later |

Beelink and Intel both state 16 GB as the maximum, so the lab is planned within that.
Sources and BIOS settings are in [docs/01](docs/01-hardware.md).

## 🧪 Labs

| Lab | Segment | Guests | Status | Certifications it serves |
|---|---|---|---|---|
| **PAM** | `pam` (no internet) | PAMv1 appliance; targets and vendor appliances next | 🟢 in code | WALLIX WCE-P, CyberArk Defender / Sentry |
| **DevOps** | `devops` (internet) | Kubernetes from cloud images, a Git forge with CI, monitoring | 🟡 planned | CKA, CKS |
| **Cyber range** | `cyber` (never routed) | attacker and vulnerable OVAs | 🟡 planned | CEH, OSCP practice |

Details are in [docs/06](docs/06-pam-lab.md) and [docs/08](docs/08-roadmap.md).

## 📚 Documentation

| # | Doc | What's inside |
|---|---|---|
| 01 | [Hardware](docs/01-hardware.md) | verified specs, the 16 GB-per-node budget, BIOS settings |
| 02 | [Network](docs/02-network.md) | address plan, VLAN vs VXLAN, gateway policy, reaching the lab from the Mac |
| 03 | [Install](docs/03-install.md) | Proxmox VE on each node, first contact from the Mac |
| 04 | [Cluster](docs/04-cluster.md) | forming it, two-node quorum, adding pve3 |
| 05 | [IaC workflow](docs/05-iac-workflow.md) | what declares what, the order, state and secrets, known limits |
| 06 | [PAM lab](docs/06-pam-lab.md) | PAMv1 from build to reset |
| 07 | [Remote management](docs/07-remote-management.md) | LAN, Tailscale, TLS trust, Wake-on-LAN, hardening |
| 08 | [Roadmap](docs/08-roadmap.md) | phases, mapped to the certification plan |

## 📁 Repository map

```
config/lab.yml            the lab, declared once
ansible/
  inventory/              hosts and addresses (read by OpenTofu too)
  playbooks/              pve-postinstall · pve-iac · lab-gateway · remote-access
  roles/                  pve_base · pve_iac · lab_gateway · tailscale
terraform/                provider · sdn · pools · gateway · vms (bpg/proxmox, locked)
scripts/
  ova-unpack.sh           OVA → verified disks + the lab.yml entry
  lab-ctl.sh              lab power and snapshots over the Proxmox API
docs/                     01–08, read in order the first time
Makefile                  the entry point: `make` lists everything
.github/workflows/        offline checks on every push
```

## 🔎 Status

> [!IMPORTANT]
> **Validated offline, not yet applied to the hardware.** CI passes on every push. Each
> piece has also been exercised without a cluster:
> - the scripts, against stubbed Proxmox APIs, under macOS's bash 3.2;
> - `tofu plan` with no cluster behind it;
> - the gateway templates, rendered for a minimal and a full config.
>
> Expect small fixes on first contact with the real nodes. [docs/05](docs/05-iac-workflow.md#known-limits-of-the-code) lists the known limits.

## 🧭 Principles

1. **Declare, don't click.** If it can be code, it is code. The few manual steps are listed with the reason ([docs/05](docs/05-iac-workflow.md#still-manual-and-why)).
2. **One place per fact.** Values live in `config/lab.yml` or the inventory, nowhere else.
3. **Least surprise for the cluster.** Node changes roll one node at a time, VMs are created stopped, and OpenTofu ignores power state, so `make plan` never shows a running lab as drift to undo.
4. **Isolation first.** Lab nets cannot reach the home LAN, and the cyber range reaches nothing.
5. **Say where facts come from.** Sources are linked; anything unverified says so.
