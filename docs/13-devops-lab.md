# 13. The DevOps lab

A two-node Kubernetes cluster ([k3s](https://k3s.io)) on the `devops` segment, for DevOps
practice. No certificate depends on it: the `Cyber-Career` plan dropped the CKS on
13 September 2026 and keeps the CKA only as a line already on the CV
([08](08-roadmap.md#phase-2-devops-devops-segment-internet-allowed)).

Everything is code. The VMs come from the Debian 13 cloud image, not from an OVA, and k3s
from its release binary, checked by SHA-256.

| Guest | VMID | Node | Address | Size | Role |
|---|---|---|---|---|---|
| `k3s1` | 2001 | `pve1` | `10.10.20.11` | 2 cores, 2 GB, 20 GB | k3s server |
| `k3s2` | 2002 | `pve2` | `10.10.20.12` | 2 cores, 2 GB, 20 GB | k3s agent |

The sizes are k3s's documented minimum for a server, "2 cores" and "2 GB"
([requirements](https://docs.k3s.io/installation/requirements)). An agent needs only
"1 core" and "512 MB", but workloads need room. `devops` has internet access for container
images and packages, and only your LAN reaches it, through `labgw`
([02](02-network.md#the-gateways-policy)).

## Where it is declared

- **`config/lab.yml`:** the `devops` entry in `gateway.nets`, and `labs.devops.vms` with
  `cloud_init: true`. That flag makes `terraform/cloud_vms.tf` build the VM from the
  cloud image with cloud-init.
- **`ansible/inventory/hosts.yml`:** the `devops` group, with children `k3s_server` and
  `k3s_agents`, holds the addresses. cloud-init sets them, and labgw publishes them as
  `k3s1.lab.home.arpa` and `k3s2.lab.home.arpa`.
- **`ansible/roles/k3s`:** installs k3s without piping an installer into `sh`:
  - the binary from the GitHub release, checked against its `sha256sum-amd64.txt`;
  - the systemd unit k3s's own install script writes;
  - `/etc/rancher/k3s/config.yaml`, which k3s reads on start ("CLI arguments map to their
    respective YAML key", [configuration](https://docs.k3s.io/installation/configuration)).

  The pinned version, `v1.36.5+k3s1`, is what k3s's stable channel pointed to in
  October 2026.

To add a node, add an entry to `labs.devops.vms` and a host under `k3s_agents`, then run
`make apply` and `make devops`.

## Build it

After the first `make apply` (which creates both VMs, stopped):

```sh
make control                     # ssh names for k3s1 and k3s2, from the inventory
make lab LAB=devops CMD=start
ssh k3s1 true; ssh k3s2 true     # accept each host key once
make devops                      # security updates, then k3s: server first, then the agent
export KUBECONFIG=~/.config/lab/kubeconfig
kubectl get nodes                # k3s1 and k3s2, Ready
```

- **The kubeconfig is the cluster's admin credential.** `make devops` copies k3s's
  `/etc/rancher/k3s/k3s.yaml` to `~/.config/lab/kubeconfig` (0600), pointed at `k3s1`. k3s's
  docs say to "replace the value of the `server` field with the IP or name of your K3s
  server", and they warn that k3s refreshes the certificates in that file on startup. If
  `kubectl` starts failing on certificates, run `make devops` again to refresh the copy.
- **The Mac needs a route** to `10.10.20.0/24` via `labgw`
  ([02](02-network.md#reaching-the-lab-from-the-mac)).
- **kubectl** is in the Brewfile (`kubernetes-cli`).
- **`make tui`** shows the lab in its Labs tab and the Kubernetes API (`k3s1:6443`) in Apps.

## Day to day

```sh
make lab LAB=devops CMD=stop                  # free 4 GB for another lab
make lab LAB=devops CMD=snapshot NAME=clean   # with the lab stopped
```

**Memory.** The two VMs take 4 GB together. The WALLIX lab needs most of the cluster
([06](06-wallix-lab.md)), so run one of them at a time.

**Upgrading k3s:** set `k3s_version` and `k3s_sha256` in `ansible/roles/k3s/defaults/main.yml`
from the new release's `sha256sum-amd64.txt`, then run `make devops`. The binary is
replaced and k3s restarts.

**Logs:** `devops` is a routed net, so its guests may send syslog and OTLP to `obs`
([10](10-observability.md)).

**Backups:** none. The VMs rebuild from code; workloads should too.

## Not yet

- A Git forge with CI runners, the other half of [phase 2](08-roadmap.md).
- A node per physical machine once `pve3` exists.

## Tested so far

Offline only:
- The OpenTofu plan builds both VMs with their inventory addresses, an image on each node,
  and labgw's `eth4`.
- The gateway templates render `devops` with DHCP, DNS, internet and the collector rules,
  and the host records.
- The role's `get_url` downloaded the pinned release and its checksum matched. The server and
  agent configs and units rendered as expected, the agent with the server's address and
  token, and the kubeconfig's server field was rewritten.

Not yet run on the VMs.
