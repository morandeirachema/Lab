# 8. Roadmap: certifications, DevOps and the cyber range

Every phase is a change to `config/lab.yml` plus `make apply`, using the same
segments, gateway and import path.

The certification targets come from the `Cyber-Career` plan. Sizes below are estimates;
check each against the [16 GB-per-node budget](01-hardware.md#capacity-plan-16-gb-per-node-by-design)
before adding it.

## Phase 0: foundation (in code now)

Proxmox on two S12 Pro nodes, the `lab` SDN zone, pools, the lab gateway, remote
management and CI. See docs 01–07.

## Phase 1: WALLIX lab (in code now)

A fully WALLIX PAM lab on the `pam` segment, from the WALLIX OVAs
([06-wallix-lab.md](06-wallix-lab.md)). → **WALLIX WCE-P**: the plan hopes for the week of
12 October 2026, or 16 November to December 2026 if it slips (WCP-P is held).

Windows guests are the costly part, at roughly 2–4 GB each. Plan two to three of them
across the two nodes.

## Observability (in code now)

A 4 GB SIEM-lite: WALLIX syslog into Loki, Proxmox metrics into Prometheus, Grafana on top
([10](10-observability.md)). **Wazuh**, a full SIEM, needs 8 GiB by its own quickstart, so it
waits for pve3 (phase 4).

## Phase 2: DevOps (`devops` segment, internet allowed)

- **In code:**
  - `devops` is in `gateway.nets`, with `internet: true`.
  - Lab VMs can be built from the Debian cloud image with cloud-init (`cloud_init: true`).
  - A two-node k3s cluster runs on them, installed by `make devops`
    ([13](13-devops-lab.md)).
  - A Forgejo forge with an Actions runner (Docker jobs), from the same `make devops`.
- **Next:** CI that deploys into k3s. Prometheus and Grafana already run on `obs`.
- No certificate depends on it. The plan dropped the **CKS** on 13 September 2026 and keeps
  the **CKA** only as a line already on the CV.

As declared in `config/lab.yml`: three 2 GB VMs (`k3s1`, `k3s2`, `forge`), 6 GB in all,
across both nodes. Heavier workloads, such as more agents or CI that deploys into k3s,
want `pve3`.

## Phase 3: cyber range (in code, `cyber` segment, isolated)

- `cyber` is an isolated gateway net: `labgw` gives its guests a DHCP lease and nothing
  else, with no route in or out, the LAN included. You reach its guests through the
  Proxmox console. A jump VM with legs on two nets would route around the policy, so
  there is none ([11](11-cyber-range.md)).
- Kali from its signed QEMU image (`make kali`), plus vulnerable targets via `make unpack`.
  → **CEH** (April 2027 in the plan). The plan deliberately leaves OSCP out.
- Log collection from the range for the blue-team side: opt-in, with `collector: true`.
- **CISSP** (September 2027) is a knowledge exam with no lab requirement.
  [12](12-cissp-projects.md) turns the lab into one project per domain.
- Later, with `pve3`: an IDS on the range, for CEH's *Evading IDS, Firewalls, and
  Honeypots* module and for CISSP's detection objectives.

**After the CISSP**, the plan's last block is HTB Academy's Active Directory modules
(October to December 2027). They run in HTB's own VPN labs, so they need nothing from this
lab. The SC-300 left the dated plan on 12 October 2026, when the plan was set to end in
December 2027.

## Phase 4: when the S13 Pro arrives

- Join it as in [04-cluster.md](04-cluster.md#adding-pve3-the-s13-pro). With three nodes
  quorum survives one node down, so remove the QDevice.
- Storage replication between nodes (`proxmox_replication` in OpenTofu). It needs ZFS with
  the same pool on every node, which the installer choice in [03-install.md](03-install.md)
  gives.
- Backups: `vzdump` to a disk in an S12 Pro's 2.5" bay, or a Proxmox Backup Server.
  OpenTofu can declare the storage (`proxmox_storage_directory` / `proxmox_storage_pbs`)
  and the job (`proxmox_backup_job`).
- About 37 GB for guests in total, which makes phase 2 practical, and makes room for Wazuh
  (4 vCPU / 8 GiB for 1–25 agents, per its quickstart) next to the SIEM-lite or in its place.
