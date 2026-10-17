# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Infrastructure as code for a Proxmox VE 9 homelab: two Beelink Mini S12 Pro nodes
(`pve1`, `pve2`), an S13 Pro (`pve3`) later, a Synology DS224+ and a Mac mini as control
node. It runs a PAM lab first (the owner's PAMv1 appliance, imported from a VirtualBox
OVA), with DevOps and cyber-range labs planned. Read `README.md` and `docs/05-iac-workflow.md`
for the full picture.

## Commands

Everything goes through `make` (run `make` to list targets). `make check` is exactly what
CI runs (`.github/workflows/check.yml`) and needs no cluster:

```sh
make check                      # shellcheck + yamllint + ansible --syntax-check + tofu fmt/validate
shellcheck scripts/lab-ctl.sh   # one script
yamllint -s config/lab.yml      # one YAML file (config: .yamllint.yml)
cd ansible && ansible-playbook --syntax-check playbooks/lab-gateway.yml   # one playbook
cd terraform && tofu validate
```

**Plan without a cluster.** Nothing exists in state, so the provider makes no API call. This
evaluates every local, `for_each` and precondition against the real YAML:

```sh
cd terraform && PROXMOX_VE_API_TOKEN='terraform@pve!provider=x' \
  tofu plan -refresh=false -input=false -lock=false -state=/tmp/scratch.tfstate
```

Without `artifacts/…vmdk` present, the plan stops at the disk-image precondition (expected).
Create a dummy file there to see the full plan, then delete it.

**Ansible in this harness** fails with "Ansible requires blocking IO" unless stdio is
redirected: `ansible-playbook … </dev/null >out.txt 2>&1`.

There is no test suite. Scripts were tested by putting stub `qm`/`pvesh`/`curl`/`pct`
executables first in `PATH` that log their arguments and return canned Proxmox JSON.
Do the same for changes to `scripts/`.

## Architecture

**One declaration, two consumers.** `config/lab.yml` declares the lab (LAN, storage, SDN
zone/vnets, pools, gateway, NAS, `labs.<lab>.vms`). `ansible/inventory/hosts.yml` holds
**every address**: Proxmox nodes, `labgw`, the NAS. OpenTofu reads both files with
`yamldecode` (`terraform/locals.tf`). Ansible reads `lab.yml` via `include_vars … name: lab`
(`playbooks/lab-gateway.yml`). Never duplicate a value from either file elsewhere.

**Layers.**
- Ansible roles configure hosts: `pve_base` per node, `pve_iac` once per cluster,
  `lab_gateway` inside the gateway container, and `tailscale`.
- OpenTofu (`bpg/proxmox`, locked) creates the Proxmox objects: SDN, pools, the gateway
  container, disk uploads, VMs, and NAS storage/backup jobs.
- `scripts/` does the imperative bits:
  - `ova-unpack.sh` extracts and verifies OVAs on the Mac.
  - `lab-ctl.sh` handles power and snapshots over the API.

**Bootstrap order matters.** `make nodes` → manual `pvecm create/add` (a joining node must
have no guests) → `make iac` → `make apply` → `make gateway`. `make iac` writes the
token, `terraform@pve!provider=<secret>`, to `~/.config/lab/proxmox-api-token`.
`make plan/apply` and `lab-ctl.sh` read it from there.

**Cross-file contracts** (changing one side breaks the other):
- Gateway interfaces: `eth0` is the LAN, then `eth1`, `eth2`, … follow the order of
  `gateway.nets`. `terraform/gateway.tf` creates them that way, and the `lab_gateway`
  templates (`nftables.conf.j2`, `dnsmasq-lab.conf.j2`) index them with `loop.index`.
- Lab membership: `terraform/vms.tf` tags each VM `lab` + `<labname>` and puts it in pool
  `<labname>`. `scripts/lab-ctl.sh` finds a lab's guests by that tag, and VMID order is
  boot order.
- OVA path: `ova-unpack.sh` extracts into `artifacts/ova/<name>/` (git-ignored) and prints
  the `lab.yml` entry. `vms.tf` uploads each disk as `proxmox_virtual_environment_file`
  (`content_type = "import"`) and attaches it with `disk.import_from`.

**Deliberate behaviours.**
- VMs are created with `started = false` and `ignore_changes = [started]`. Power belongs to
  `lab-ctl.sh`; don't make OpenTofu manage it.
- SDN changes are applied by the `proxmox_sdn_applier` "lab" + "finalizer" pair, the
  pattern from the provider's docs.
- `terraform_data.config_checks` and per-resource preconditions validate `lab.yml` at
  plan time.

## Constraints learned the hard way

- **Provider resource names.** Use `proxmox_virtual_environment_vm` and
  `_container`; `proxmox_vm` is marked experimental, not for production. Use the short
  `proxmox_sdn_*`, `proxmox_download_file`, `proxmox_user_token` and `proxmox_acl`; their
  `proxmox_virtual_environment_*` twins are deprecated. Check attributes against
  `tofu providers schema -json` or the provider docs at the locked tag (v0.116.1) before
  writing HCL.
- **Import uploads** accept only `.raw`, `.qcow2` and `.vmdk` (lower-case: PVE matches
  extensions case-sensitively). Uploading an `.ova` isn't possible, hence `ova-unpack.sh`.
  A disk's `size_gb` must be ≥ the image's capacity, because the provider resizes and
  cannot shrink.
- **SDN zone/vnet IDs** are 2–8 characters, matching `[a-zA-Z][a-zA-Z0-9]*[a-zA-Z0-9]`.
  No `-` or `_`.
- **Switching `sdn.type`** (vlan ↔ vxlan) after the first apply needs a teardown: PVE
  won't delete a zone that still has vnets.
- **`scripts/*.sh` run on macOS**, so they must work in bash 3.2. That rules out `${x,,}`,
  `mapfile` and associative arrays. Empty arrays under `set -u` need
  `${a[@]+"${a[@]}"}`. `lab-ctl.sh` keeps action calls inside `|| rc=1`, so check errors
  explicitly there; `set -e` is suspended in that context.
- **macOS `sed`** has no `\|` alternation, and `ls` may be aliased (use `command ls`).
- Hardware ceiling: N100/N150 and the S12 Pro are **16 GB max** (Intel ARK, Beelink
  staff). Plan guests within it. The S13 Pro has no official spec page.

## Working agreements with the owner

- **No fabrications.** Every hardware spec, command flag or version must come from a
  primary source (vendor page, Proxmox docs/source, provider schema/docs), and the docs
  link it. If a fact can't be verified, say so in the text ("verify on arrival",
  "community-reported"). Check action and tool versions before pinning them.
- **IaC for everything possible.** If something must stay manual, add it to the "Still
  manual, and why" table in `docs/05-iac-workflow.md`.
- **Commit step by step.** One coherent change per commit. Subjects look like
  `area: what changed`. Bodies explain why, and say what was tested and what wasn't
  (e.g. "not yet applied to a cluster"). The remote is the private GitHub repo
  `morandeirachema/Lab`.
- Nothing has been applied to real hardware yet. Treat the first `make apply` as a test.
