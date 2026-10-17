# 8. Roadmap: certifications, DevOps and the cyber range

Every phase is a change to `config/lab.yml` plus `make apply`, using the same
segments, gateway and import path.

The certification targets come from the `Cyber-Career` plan. Sizes below are estimates;
check each against the [16 GB-per-node budget](01-hardware.md#capacity-plan-16-gb-per-node-by-design)
before adding it.

## Phase 0: foundation (in code now)

Proxmox on two S12 Pro nodes, the `lab` SDN zone, pools, the lab gateway, remote
management and CI. See docs 01–07.

## Phase 1: PAM lab (in code now: PAMv1)

| Next | Why | Certification |
|---|---|---|
| **Targets** under `labs.pam.vms`: a Linux SSH target, an RDP target | A PAM lab needs something to broker sessions to | All PAM tracks |
| A Windows domain controller (AD) | Most PAM exercises assume AD accounts | All PAM tracks |
| **WALLIX Bastion**, if you have an image of it (training or trial). An OVA goes through `make unpack` | WCE-P is expected before November 2026 in the plan; WCP-P is held | WALLIX WCE-P |
| CyberArk components, if you have images | | CyberArk Defender / Sentry |

Windows guests are the costly part, at roughly 2–4 GB each. Plan two to three of them
across the two nodes.

## Phase 2: DevOps (`devops` segment, internet allowed)

- Add `devops` to `gateway.nets` with `internet: true`.
- A Debian cloud image as an OpenTofu `proxmox_download_file` with
  `content_type = "import"`. Proxmox accepts `.qcow2` for import. VMs use it with
  cloud-init, so they are built from code and not from an OVA.
- A three-VM Kubernetes cluster (kubeadm), one VM per node once `pve3` exists. → **CKA**,
  then **CKS** (hardening, policies, runtime security).
- PAMv1 on that cluster, with its own `deploy/helm` chart: the same product, deployed the
  DevOps way.
- A Git forge with CI runners, and Prometheus/Grafana for the nodes and guests.

Rough size: 3 × 4 GB for Kubernetes, plus 2–4 GB for the forge and monitoring. This
phase really wants `pve3`.

## Phase 3: cyber range (`cyber` segment, never routed)

- `cyber` stays out of `gateway.nets`: no internet, no LAN, nothing in or out. You reach
  it only through the Proxmox console, or a jump VM with one leg on `cyber` and one on
  `pam`.
- An attacker VM plus vulnerable targets. Vulnerable boxes are often distributed as
  OVAs, so `make unpack` works for them as is. → **CEH**, **OSCP** practice.
- Log collection from the range, for the blue-team side. → supports the security-operations
  part of **CISSP**. CISSP itself is a knowledge exam with no lab requirement.

**SC-300** (Microsoft Entra) is cloud-side. The lab's AD domain controller matters for
it only in hybrid-identity exercises.

## Phase 4: when the S13 Pro arrives

- Join it as in [04-cluster.md](04-cluster.md#adding-pve3-the-s13-pro). With three nodes
  quorum survives one node down, so remove the QDevice.
- Storage replication between nodes (`proxmox_replication` in OpenTofu). It needs ZFS with
  the same pool on every node, which the installer choice in [03-install.md](03-install.md)
  gives.
- Backups: `vzdump` to a disk in an S12 Pro's 2.5" bay, or a Proxmox Backup Server.
  OpenTofu can declare the storage (`proxmox_storage_directory` / `proxmox_storage_pbs`)
  and the job (`proxmox_backup_job`).
- About 37 GB for guests in total, which makes phase 2 practical.
