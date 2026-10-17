# 5. How the lab is built: infrastructure as code

## What declares what

| Layer | Tool | Files | What it owns |
|---|---|---|---|
| Declaration | (YAML) | `config/lab.yml`, `ansible/inventory/hosts.yml` | The lab itself: LAN, segments, pools, gateway, every lab's guests; all host addresses |
| Node configuration | Ansible | `ansible/roles/pve_base` | Repositories, upgrades, tools, swappiness, ZFS ARC, gateway kernel modules, SSH, static routes |
| Cluster prerequisites | Ansible | `ansible/roles/pve_iac` | `terraform@pve`, the `Terraform` role, its API token, `import` content on `local` |
| Proxmox objects | OpenTofu | `terraform/` | SDN zone and vnets, pools, the container template, the gateway container, uploaded disk images, lab VMs |
| Inside the gateway | Ansible | `ansible/roles/lab_gateway` | dnsmasq and nftables, rendered from `config/lab.yml` |
| Remote access | Ansible | `ansible/roles/tailscale` | Tailscale on the nodes, subnet routes |
| Operations | scripts | `scripts/lab-ctl.sh`, `scripts/ova-unpack.sh` | Power, snapshots and rollbacks over the API; unpacking an OVA for import |

OpenTofu reads both YAML files, and Ansible reads `config/lab.yml`, so a value is never
written twice. CI (`.github/workflows/check.yml`) runs `make check` on every push. It
validates the shell scripts, the YAML, every playbook's syntax and the OpenTofu code
against the provider's real schema, without touching the cluster.

## Still manual, and why

| Step | Why it is not code |
|---|---|
| BIOS settings, Proxmox install | Nothing to run code on yet |
| `pvecm create` / `pvecm add` | Interactive (root password, fingerprint), and done once |
| Approving Tailscale routes | Done in the Tailscale admin console, by design |
| Getting the WALLIX OVAs | They come from WALLIX; `make unpack` takes them from there |
| Power state and snapshots | Day-to-day operations, not desired state: `make lab` |

## Order, for a fresh cluster

```sh
make check                       # offline: everything validates
make ping && make nodes          # 03-install.md: baseline every node
# form the cluster by hand:      # 04-cluster.md
make iac                         # API user, role, token → ~/.config/lab/proxmox-api-token
make unpack OVA=~/path/to/<wallix-appliance>.ova      # each OVA: 06-wallix-lab.md
cp terraform/terraform.tfvars.example terraform/terraform.tfvars # add your SSH public key
make init                        # OpenTofu providers, pinned by the lock file
make plan                        # read it
make apply                       # SDN, pools, gateway container, WALLIX VMs
make gateway                     # dnsmasq + nftables inside the gateway
make lab LAB=wallix CMD=start
```

To change anything later, edit `config/lab.yml` and run `make plan`, then `make apply`.
If the change concerns the gateway's nets, run `make gateway` too.

## State and secrets

- **OpenTofu state** is `terraform/terraform.tfstate`, on your Mac only (git-ignored).
  Back it up like any other file you can't recreate easily. If it is lost, the lab still
  runs; you would re-adopt the resources with `tofu import`.
- **The API token** is in `~/.config/lab/proxmox-api-token` (mode 0600). Proxmox shows a
  token's secret once, at creation. To replace it, run
  `pveum user token remove terraform@pve provider` on a node, then `make iac`.
- **The token's privileges** are the `Terraform` role from the bpg/proxmox provider
  docs. Those docs say the list is "only an example (and likely too permissive for most
  use cases)". Trimming it is a sensible later exercise.
- **The Tailscale auth key** is read from `TS_AUTHKEY` at run time and never stored.
- **Disk images and OVAs** are git-ignored (`artifacts/`, `*.ova`, `*.vmdk`).

## Known limits of the code

- Nothing here has been applied to a real cluster yet. The OpenTofu plan, the rendered
  gateway configs and the scripts have been exercised offline only (stubs, `tofu plan`
  without a cluster, `--syntax-check`). Expect small fixes on first contact.
- The provider's `proxmox_sdn_applier` is marked **experimental** by its authors.
- VMs are created stopped, and OpenTofu ignores their power state afterwards. That is
  deliberate, so `make apply` never shuts down a running lab.
