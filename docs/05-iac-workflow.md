# 5. How the lab is built: infrastructure as code

## What declares what

| Layer | Tool | Files | What it owns |
|---|---|---|---|
| Declaration | (YAML) | `config/lab.yml`, `ansible/inventory/hosts.yml` | The lab itself: LAN, segments, pools, gateway, every lab's guests; all host addresses |
| Node configuration | Ansible | `ansible/roles/pve_base` | Repositories, upgrades, tools, swappiness, ZFS ARC, gateway kernel modules, SSH, static routes |
| DevOps lab | Ansible | `ansible/roles/k3s`, `ansible/roles/forgejo` | k3s and Forgejo with its runner, from checked release binaries; the kubeconfig and the forge's first admin password on the Mac |
| Cluster prerequisites | Ansible | `ansible/roles/pve_iac` | `terraform@pve`, the `Terraform` role, its API token, `import` content on `local` |
| Proxmox objects | OpenTofu | `terraform/` | SDN zone and vnets, pools, the container template, the gateway container, uploaded disk images, lab VMs from images or from the Debian cloud image, `obs`, NAS storage and backup jobs |
| Inside the gateway | Ansible | `ansible/roles/lab_gateway` | dnsmasq and nftables, rendered from `config/lab.yml` |
| Observability | Ansible | `ansible/roles/observability` | Alloy, Loki, Prometheus and Grafana on the `obs` VM |
| Remote access | Ansible | `ansible/roles/tailscale` | Tailscale on the nodes, subnet routes |
| Operations | scripts | `scripts/lab-ctl.sh`, `scripts/ova-unpack.sh`, `scripts/kali-fetch.sh` | Power, snapshots and rollbacks over the API; unpacking an OVA, or fetching Kali's signed QEMU image, for import |
| Console UI | Python (uv) | `tui/labtui.py` | `make tui`: live state, power and snapshot actions (lab-wide ones through lab-ctl), app health, the `make` workflows |

OpenTofu reads both YAML files, and Ansible reads `config/lab.yml`, so a value is never
written twice. CI (`.github/workflows/check.yml`) runs `make check` on every push. It
validates the shell scripts, the YAML, every playbook (syntax, and ansible-lint's
`production` profile) and the OpenTofu code against the provider's real schema, and runs
the console UI's tests, all without touching the cluster.

## Still manual, and why

| Step | Why it is not code |
|---|---|
| BIOS settings, Proxmox install | Nothing to run code on yet |
| Switch ports (with `sdn.type: vlan`) | Trunks carrying tags 10/20/30/40, and no IP interface on VLAN 30: the switch's own UI ([02](02-network.md#vlan-or-vxlan)) |
| Home router: static addresses, optional static routes | Keep the inventory's addresses outside its DHCP pool; the router's own UI ([02](02-network.md#address-plan)) |
| Copying your SSH key to each node | `ssh-copy-id pve1` etc.: needs each node's root password once ([03](03-install.md#first-contact-from-the-mac)) |
| `pvecm create` / `pvecm add` | Interactive (root password, fingerprint), and done once |
| `pvecm qdevice setup` | One-time pairing over root SSH; `make qdevice` prepares both sides |
| Approving Tailscale routes | Done in the Tailscale admin console, by design |
| NAS volume, `proxmox` share, NFS rules | DSM is configured in its own UI ([09](09-nas-and-control-node.md)); OpenTofu then adds the storage |
| Pi-hole's `dns.revServers` entry | One setting in an existing container on the NAS ([09](09-nas-and-control-node.md#5-lab-names-through-pi-hole)) |
| Mac mini as control node: `pmset`, Remote Login | macOS settings behind an admin password, wanted on the mini only; its tools (`make tools`) and SSH names (`make control`) are code ([09](09-nas-and-control-node.md)) |
| SSH from the MacBook Neo to the Mac mini: a key and a `Host macmini` entry | Only what macOS ships (`ssh`, `ssh-copy-id`), so nothing gets installed on the MacBook; `ssh-copy-id` asks for the Mac mini's password once ([09](09-nas-and-control-node.md#from-the-macbook-neo)) |
| Trusting the cluster CA in macOS, turning TLS verification on | `make iac` copies the CA; the Keychain import needs `sudo`, and verification first needs the certificate names checked ([07](07-remote-management.md#3-trusting-the-clusters-certificate)) |
| Two-factor login for the web UI | Enrolling a TOTP secret is done by whoever holds the authenticator ([07](07-remote-management.md#hardening-checklist)) |
| Accepting SSH host keys | First `ssh` to each node, `labgw`, `obs` and the DevOps VMs; Ansible checks host keys and won't accept them silently |
| Downloading target images for the range | Third-party downloads, each with its own terms; `make unpack` takes over from the file ([11](11-cyber-range.md#build-it)) |
| Forgejo's first admin login | Forgejo requires a new password for a created user at first login; `make devops` saves the generated one ([13](13-devops-lab.md#the-forge)) |
| Kali's first password change | Inside the guest, from the Proxmox console: the range has no path from the Mac, by design ([11](11-cyber-range.md#build-it)) |
| Turning on `observability.metrics_push` | Proxmox refuses a metric server nobody answers, so it's created after `make obs` ([10](10-observability.md#build-it)) |
| WALLIX first boot: wizard, network, license | Inside each appliance's console; the license comes from WALLIX Support ([06](06-wallix-lab.md)) |
| Pointing WALLIX at the collector | The Bastion's System → SIEM integration / Syslog pages ([10](10-observability.md#send-wallixs-logs-to-it)) |
| Pointing range targets at the collector (opt-in) | Inside untrusted guests, from the console, only with `collector: true` ([11](11-cyber-range.md#the-blue-side)) |
| Grafana's contact point | Where alerts go (email, chat) is your choice and needs its own credentials. Rules, dashboards and data sources are provisioned ([10](10-observability.md#keep-them-as-code)) |
| Upgrading Grafana, Loki, Alloy | Kept out of unattended upgrades on purpose, so a new major can't break the configs (`apt upgrade` on `obs`) |
| Routes from the Mac to the lab nets | A router or Mac setting ([02](02-network.md#reaching-the-lab-from-the-mac)); Ansible reaches `obs` (`10.10.40.10`) through it |
| Getting the WALLIX OVAs | They come from WALLIX; `make unpack` takes them from there |
| Power state and snapshots | Day-to-day operations, not desired state: `make lab` |

## Order, for a fresh cluster

Every manual step from the table above appears here as a comment, where it falls.

```sh
# --- The Mac (03-install.md, 09-nas-and-control-node.md)
make tools && make control       # tools from the Brewfile; ssh pve1/labgw/obs from the inventory
make check                       # offline: everything validates

# --- The nodes (03-install.md, 04-cluster.md)
# by hand: switch trunks, router reservations, BIOS, Proxmox install on each node
ssh-copy-id pve1; ssh-copy-id pve2   # host key and root password, once per node
make ping && make nodes          # baseline every node: repos, upgrades, ARC, routes, Wake-on-LAN
# by hand: pvecm create / pvecm add (04-cluster.md)
make qdevice                     # two nodes only: then ssh pve1 pvecm qdevice setup <ip>
make iac                         # API user, role, token and the cluster CA → ~/.config/lab/

# --- The lab (06-wallix-lab.md, 11-cyber-range.md)
make unpack OVA=~/path/to/<wallix-appliance>.ova      # each OVA, pasted into labs.wallix.vms
make kali                        # the range's attacker VM, pasted into labs.cyber.vms
ssh-add                          # your key in ssh-agent: OpenTofu's node SSH, and the guests' key
make init && make plan           # OpenTofu providers from the lock file; read the plan
make apply                       # SDN, pools, labgw, obs, the lab VMs (stopped)
make gateway                     # dnsmasq + nftables inside labgw
# by hand: routes from the Mac to the routed lab nets via labgw (02-network.md)

# --- Observability (10-observability.md)
export GRAFANA_ADMIN_PASSWORD=…  # first run of make obs only
make obs                         # Alloy, Loki, Prometheus, Grafana, its alert and dashboard
# set observability.metrics_push: true in config/lab.yml, then:
make apply                       # Proxmox's metric server (needs Alloy up)

# --- The DevOps lab (13-devops-lab.md)
make lab LAB=devops CMD=start
make devops                      # k3s on k3s1 + k3s2, Forgejo + runner on forge; credentials → ~/.config/lab/
# by hand: Forgejo's first login, which makes you replace the generated admin password

# --- Use it
make lab LAB=wallix CMD=start    # by hand: WALLIX's first-boot wizard and license, in its console

# --- Any time later
#   NAS share ready (09):  nas.enabled: true in config/lab.yml, then make apply
#   Tailscale (07):        tailscale_enabled: true, export TS_AUTHKEY=…, make remote
#   MacBook Neo (09):      by hand: Remote Login on the Mac mini; Host macmini, ssh-copy-id macmini
#   Hardening (07):        pve_base_ssh_disable_passwords: true, make nodes; TOTP; TLS verification
```

To change anything later, edit `config/lab.yml` and run `make plan`, then `make apply`.
If the change concerns the gateway's nets, also run `make gateway` (its DHCP/DNS and firewall)
and `make routes` (the nodes' routes to them).

## State and secrets

- **OpenTofu state** is `terraform/terraform.tfstate`, on the Mac mini only (git-ignored;
  [09](09-nas-and-control-node.md#tools-and-repo)).
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
