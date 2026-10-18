# 13. The DevOps lab

A two-node Kubernetes cluster ([k3s](https://k3s.io)) and a Git forge with CI
([Forgejo](https://forgejo.org) and its Actions runner) on the `devops` segment, for DevOps
practice. No certificate depends on it: the `Cyber-Career` plan dropped the CKS on
13 September 2026 and keeps the CKA only as a line already on the CV
([08](08-roadmap.md#phase-2-devops-devops-segment-internet-allowed)).

Everything is code. The VMs come from the Debian 13 cloud image, not from an OVA. k3s and
Forgejo come from their release binaries, checked by SHA-256.

| Guest | VMID | Node | Address | Size | Role |
|---|---|---|---|---|---|
| `k3s1` | 2001 | `pve1` | `10.10.20.11` | 2 cores, 2 GB, 20 GB | k3s server |
| `k3s2` | 2002 | `pve2` | `10.10.20.12` | 2 cores, 2 GB, 20 GB | k3s agent |
| `forge` | 2003 | `pve2` | `10.10.20.20` | 2 cores, 2 GB, 40 GB | Forgejo + Actions runner |

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

## The forge

`forge` runs Forgejo **v15.0.10**, the LTS line ("supported until 15 July 2027",
[forgejo.org/releases](https://forgejo.org/releases/)), with SQLite. Its Actions runner,
v13.2.0, runs on the same VM. Both binaries' `.asc` signatures were checked against
Forgejo's release key `EB114F5E6C0DC2BCDD183550A4B61A2DC5923710`
([download page](https://forgejo.org/download/)) before their SHA-256 was pinned. `ansible/roles/forgejo` follows
Forgejo's [binary installation guide](https://forgejo.org/docs/v15.0/admin/installation/binary/):
a `git` user, `/var/lib/forgejo`, `/etc/forgejo/app.ini`, and Forgejo's own systemd unit.

- **No secret in a config file or on a command line.**
  - Forgejo's `SECRET_KEY`, `INTERNAL_TOKEN` and `JWT_SECRET` are generated once, on the VM.
    Each is stored in a file (root:git, 0640), and `app.ini` points at them with the `*_URI`
    keys. So `app.ini` holds no secret, and Forgejo never needs to write it.
  - Registration is off (`DISABLE_REGISTRATION`): accounts come from the admin.
- **The first admin** is `labadmin`. Forgejo generates its password (`--random-password`),
  and `make devops` saves it to `~/.config/lab/forgejo-admin-password` (0600) on the Mac.
  Forgejo's source makes a created user change their password at first login by default,
  so that file is only good once.
- **The runner** is registered offline, the way Forgejo's
  [registration docs](https://forgejo.org/docs/v15.0/admin/actions/registration/) describe
  for automated setups:
  - The shared 40-hex secret is generated on the VM and kept in two copies, one readable by
    Forgejo and one by the runner. Forgejo reads its copy with `--secret-file`, the runner
    through `token_url`.
  - The runner is global and offers one label, `docker`. Jobs run in Docker containers from
    `node:lts-trixie`, without the Docker socket mounted (`docker_host: "-"`).
  - The `runner` user is in the `docker` group, which is root on that VM. That's one more
    reason the forge lives on a lab segment.

Open **`http://10.10.20.20:3000/`** from the Mac and log in as `labadmin`. To try CI,
create a repository with `.forgejo/workflows/hello.yml`:

```yaml
on: [push]
jobs:
  hello:
    runs-on: docker
    steps:
      - uses: actions/checkout@v4   # resolved from data.forgejo.org, Forgejo's default
      - run: uname -a && ls
```

`make tui` shows Forgejo's health check (`/api/healthz`) under Apps.

## Day to day

```sh
make lab LAB=devops CMD=stop                  # free 6 GB for another lab
make lab LAB=devops CMD=snapshot NAME=clean   # with the lab stopped
```

**Memory.** The three VMs take 6 GB together. The WALLIX lab needs most of the cluster
([06](06-wallix-lab.md)), so run one of them at a time.

**Upgrades:**
- **k3s:** set `k3s_version` and `k3s_sha256` in `ansible/roles/k3s/defaults/main.yml`, from
  the new release's `sha256sum-amd64.txt`.
- **Forgejo or its runner:** set the version and `_sha256` in
  `ansible/roles/forgejo/defaults/main.yml`, after checking the new binary's `.asc` against
  the release key.

Then run `make devops`. The binaries are replaced and the services restart.

**Logs:** `devops` is a routed net, so its guests may send syslog and OTLP to `obs`
([10](10-observability.md)).

**Backups:** none yet. The VMs rebuild from code, but the forge's repositories live in
`/var/lib/forgejo`: add the `devops` pool to `nas.backup.pools` once the NAS is on, or
push them somewhere else too.

## Not yet

- Deploying from the forge's CI into k3s (a kubeconfig as a repository secret).
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
- Forgejo's `app.ini`, both units and the runner config rendered, and the runner config
  parses as YAML. The role's parsing was checked against output in the formats of Forgejo's
  v15 source (`admin user list`, `admin user create --random-password`): it tells
  `labadmin` from `labadmin2`, and it keeps a password with quotes and spaces intact.
  Forgejo's binaries are Linux-only, so they have not run here.

Not yet run on the VMs.
