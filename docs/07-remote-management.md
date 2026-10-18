# 7. Managing the nodes remotely

Four layers, from everyday use down to "the node is off".

## 1. On the home LAN

| Interface | What for |
|---|---|
| Web UI: `https://<node>:8006` | Consoles (e.g. a guest's first boot), a quick look at state |
| SSH with keys (`ssh pve1`, see [03-install.md](03-install.md#first-contact-from-the-mac)) | Ansible, one-off commands |
| API token (`terraform@pve!provider`) | OpenTofu (`make plan/apply`) and `make lab`, without logging in anywhere |

`make lab` is the remote control for labs. It talks to the Proxmox API from your Mac,
so no repo copy or SSH session on a node is involved:

```sh
make lab LAB=wallix CMD=status
make lab LAB=wallix CMD=start
make lab LAB=wallix CMD=snapshot NAME=before-exercise
```

## 2. Away from home: Tailscale

Tailscale needs no open ports on the router. Never port-forward 8006 or 22 to the
internet.

1. Enable it in `ansible/inventory/group_vars/proxmox.yml`:
   ```yaml
   tailscale_enabled: true
   ```
2. Make **one** node a subnet router for the LAN and the lab nets. Create
   `ansible/inventory/host_vars/pve1.yml`:
   ```yaml
   tailscale_advertise_routes: [192.168.1.0/24, 10.10.10.0/24, 10.10.40.0/24]
   ```
   Every node already routes the lab nets through `labgw`: `pve_base` derives the routes
   from `gateway.nets`.
3. Generate a **one-off** (not reusable) auth key in the Tailscale admin console. That's
   Tailscale's own advice in [Securely handle an auth key](https://tailscale.com/docs/features/access-control/auth-keys/how-to/secure-auth-keys).
   Load it without it landing in your shell history, then:
   ```sh
   export TS_AUTHKEY=$(cat)       # paste the key, then Ctrl-D
   make remote
   ```
4. **Approve the routes** on the admin console's *Machines* page, in that node's
   subnet settings. An advertised route is not used until it is approved, unless you
   set up autoApprovers.

Each node also gets its own tailnet address, so you can reach the web UI or SSH on any
node directly. `tailscale_accept_dns: false` keeps each node on its own DNS.

## 3. Trusting the cluster's certificate

Each cluster creates its own certificate authority. The Proxmox docs say to "copy
/etc/pve/pve-root-ca.pem from any cluster node out of band … and import it into the
operating system or browser trust store", because there is no download endpoint.

`make iac` copies it over SSH to `~/.config/lab/pve-root-ca.pem`. Adding it to the
Mac's trust store, for browsers and other Keychain users, needs your admin password, so
it stays a manual step:

```sh
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/.config/lab/pve-root-ca.pem
```

Before turning verification on, check which names the node certificate covers. The
endpoints here use IP addresses:

```sh
openssl s_client -connect 192.168.1.11:8006 </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName
```

If the address is listed:

- `make lab`: `export PROXMOX_VE_CACERT=~/.config/lab/pve-root-ca.pem`. This takes
  precedence over the Makefile's `PROXMOX_VE_INSECURE=true`.
- OpenTofu: set `proxmox_insecure = false` in `terraform/terraform.tfvars`. That relies on
  the CA being in the macOS trust store; if verification fails, keep `true` for now.

If only names are listed, point the endpoints at a listed name
(`proxmox_endpoint` / `PROXMOX_VE_ENDPOINT`).

## 4. When a node is off

These mini PCs have no IPMI. The BIOS settings in
[01-hardware.md](01-hardware.md#bios-settings-s12-pro) stand in for it:

- **After a power cut**, *State After G3 = S0* powers the node back on by itself.
- **Wake-on-LAN** is enabled in the BIOS by default. Proxmox can send the packet from
  another node:
  ```sh
  ssh pve1 pvenode wakeonlan pve2                           # from a running node
  ```
  `make nodes` registers each node's NIC for it (`pvenode config set --wakeonlan <MAC>`).
  It uses the one physical port of the LAN bridge, and says so if it finds another count.
  `pvenode wakeonlan` broadcasts the magic packet on UDP port 9. From the Mac on the same
  LAN, `brew install wakeonlan`, then `wakeonlan <MAC>`, does the same. Whether the NIC
  wakes from a *Linux* shutdown can also depend on the driver's setting; check with
  `ethtool <nic> | grep Wake-on` on the node (`g` = magic packet).

## Hardening checklist

- [ ] Key-only root SSH: `pve_base_ssh_disable_passwords: true`, then `make nodes`.
      Do this once key login works.
- [ ] Two-factor login for the web UI. Proxmox supports TOTP: *Datacenter → Permissions
      → Two Factor*.
- [ ] Trust the cluster CA and turn TLS verification on (section 3).
- [ ] Trim the `Terraform` role. The provider docs call their list "likely too
      permissive".
- [ ] No port forwards to the nodes; remote access goes only through Tailscale.
