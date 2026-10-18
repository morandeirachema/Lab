# 12. CISSP projects

CISSP is a knowledge exam; the `Cyber-Career` plan sits it in September 2027. It has no
lab requirement. These eight projects, one per domain, use the controls this lab really
has: you assess them, test them, find where they fall short, and write that down the way the
exam expects you to think. Each project names the exam-outline objectives it exercises.
The domains, weights and objective titles are quoted from ISC2's
[CISSP exam outline](https://www.isc2.org/certifications/cissp/cissp-certification-exam-outline),
effective April 15, 2024.

Write each deliverable as a short Markdown file under `study/cissp/` in this repo. They
describe this lab, so they belong next to it. Git keeps their history, which is itself
domain 7's change management.

| # | Domain (weight) | Project | Lab parts |
|---|---|---|---|
| 1 | Security and Risk Management (16%) | [Risk register and threat model](#1-risk-register-and-threat-model) | the whole lab |
| 2 | Asset Security (10%) | [Data inventory and retention](#2-data-inventory-and-retention) | secrets, logs, backups, state |
| 3 | Security Architecture and Engineering (13%) | [Design review of the segmentation](#3-design-review-of-the-segmentation) | SDN, `labgw`, `obs` |
| 4 | Communication and Network Security (13%) | [Firewall rule review](#4-firewall-rule-review) | `labgw`'s nftables and dnsmasq |
| 5 | Identity and Access Management (13%) | [Least privilege for the IaC token](#5-least-privilege-for-the-iac-token) | Proxmox RBAC, SSH, WALLIX |
| 6 | Security Assessment and Testing (12%) | [Control testing and report](#6-control-testing-and-report) | the isolation test, Lynis, CI |
| 7 | Security Operations (13%) | [Detection, patching and a restore test](#7-detection-patching-and-a-restore-test) | `obs`, unattended upgrades, NAS backups |
| 8 | Software Development Security (10%) | [Supply chain of the lab](#8-supply-chain-of-the-lab) | CI, image and package verification |

## 1. Risk register and threat model

**Objectives:** 1.9 Understand and apply risk management concepts; 1.10 Understand and
apply threat modeling concepts and methodologies; 1.11 Apply Supply Chain Risk Management
(SCRM) concepts.

**Do:** List the lab's assets (the nodes, `labgw`, `obs`, the NAS, the API token, WALLIX's
audit trail). Then threats, likelihood, impact and a treatment for each risk: accept,
mitigate, transfer or avoid. Start from risks this repo already documents:

- Third-party target images in the range ([11](11-cyber-range.md#rules-of-engagement)).
- With `sdn.type: vlan`, isolation depends on the switch's configuration ([02](02-network.md#the-gateways-policy)).
- `internet: false` nets can still resolve public names through `labgw`, a path out over DNS ([02](02-network.md#the-gateways-policy)).
- `labgw` and `obs` both run on `pve1`, a deliberate single-node dependency (`config/lab.yml`).
- Two nodes need a QDevice for quorum ([04](04-cluster.md)).
- WALLIX advisory WSA-2026-07-0001 ([06](06-wallix-lab.md)).

**Deliverable:** `study/cissp/01-risk-register.md`: a table with one row per risk and an
owner (you), plus a short threat model of `labgw` using a method of your choice (STRIDE,
for example).

**Done when:** every *mitigate* row points to a control in this repo or an issue to build
one, and every *accept* row says why.

## 2. Data inventory and retention

**Objectives:** 2.1 Identify and classify information and assets; 2.4 Manage data
lifecycle; 2.5 Ensure appropriate asset retention (e.g., End of Life (EOL), End of
Support).

**Do:** Classify every kind of data the lab holds, and record where it lives, who can read
it and how long it is kept. All of it is in the code:

- the API token, `~/.config/lab/proxmox-api-token`, mode 0600 (`pve_iac`);
- Grafana's admin password, `/etc/grafana/admin_password`, root:grafana 0640;
- logs in Loki and metrics in Prometheus, 14 days, and Prometheus also capped at 10 GB
  ([10](10-observability.md));
- backups on the NAS: keep 3 last and 4 weekly (`nas.backup` in `config/lab.yml`);
- the OpenTofu state, local and git-ignored. Find out what it contains.

Then look up each component's support end date on its vendor's page: Debian 13, Proxmox VE 9,
WALLIX Bastion, Grafana. Don't guess them.

**Deliverable:** `study/cissp/02-data-inventory.md`: classification, location, access,
retention, disposal, and an EOL table with a source link per date.

**Done when:** each retention value in the table matches the setting that enforces it,
and you have checked it on the running system.

## 3. Design review of the segmentation

**Objectives:** 3.1 Research, implement and manage engineering processes using secure
design principles; 3.5 Assess and mitigate the vulnerabilities of security architectures,
designs, and solution elements.

**Do:** For each principle, find where the lab applies it and where it doesn't:
least privilege, defence in depth, secure defaults, fail securely, separation of duties,
keep it simple. Some places to start:

- the gateway's default-drop chains;
- Loki and Prometheus on `127.0.0.1` only;
- `collector: false` by default on isolated nets;
- unprivileged containers;
- `labgw` as a single choke point, which is also a single point of failure.

**Deliverable:** `study/cissp/03-design-review.md`: principle → evidence → gap → proposed
change.

**Done when:** each gap has a proposed change you could make in `config/lab.yml` or a role.

## 4. Firewall rule review

**Objectives:** 4.1 Apply secure design principles in network architectures; 4.2 Secure
network components.

**Do:** On `labgw`, dump the live ruleset (`nft list ruleset`) and justify every rule
against [the policy table](02-network.md#the-gateways-policy). Look for rules that are
broader than they need to be. Then answer from primary sources: does VLAN tagging give
confidentiality? Does VXLAN encrypt (RFC 7348)? What does that mean for lab traffic
crossing the home switch?

**Deliverable:** `study/cissp/04-rule-review.md`: rule → purpose → verdict (keep, tighten,
remove).

**Done when:** every rule has a verdict, and each *tighten* has been tried with
`make gateway` and the isolation test from [11](11-cyber-range.md#check-the-isolation-first).

## 5. Least privilege for the IaC token

**Objectives:** 5.4 Implement and manage authorization mechanisms; 5.5 Manage the identity
and access provisioning lifecycle.

**Do:** Today `pve_iac` gives `terraform@pve` its role on `/`, with a token that has no
privilege separation (`--privsep 0`). Design a narrower grant: which paths (pools, storage,
SDN, nodes) and which privileges does OpenTofu really need? Test it with `make plan` and
`make apply`. Also review two more things:

- SSH: `pve_base_ssh_disable_passwords` is `false` in `group_vars/proxmox.yml`. When can it
  be `true`?
- Account review: run `pveum user list` and `pveum acl list` and justify every entry.
  If you are studying for WCE-P, add WALLIX's accounts and authorizations.

**Deliverable:** `study/cissp/05-access-review.md`: the current grants, the proposed grants
and the test result, plus a token rotation procedure.

**Done when:** the narrower grant works for a full `make apply`, or the review explains
which privilege blocked it and why it stays.

## 6. Control testing and report

**Objectives:** 6.2 Conduct security control testing; 6.4 Analyze test output and generate
report.

**Do:**

1. **Isolation.** Run the range's isolation test ([11](11-cyber-range.md#check-the-isolation-first))
   and record each result.
2. **Host audit.** Run Lynis on `labgw` and `obs`. Debian 13 packages it (`lynis`
   3.1.4-1, [packages.debian.org](https://packages.debian.org/trixie/lynis)).
3. **Continuous checks.** CI runs `make check` on every push
   (`.github/workflows/check.yml`). Write down what it tests and what it can't, such as
   behaviour on a live cluster.

**Deliverable:** `study/cissp/06-assessment-report.md`: scope, method, findings ranked by
risk, a remediation for each, and exceptions with their justification (the DNS path from
project 1 is a candidate).

**Done when:** every finding is fixed, ticketed, or accepted as an exception, and nothing
is left unaddressed.

## 7. Detection, patching and a restore test

**Objectives:** 7.2 Conduct logging and monitoring activities; 7.8 Implement and support
patch and vulnerability management; 7.9 Understand and participate in change management
processes; 7.12 Test Disaster Recovery Plans (DRP).

**Do:**

1. **Detection.** Write a Grafana alert rule on WALLIX's syslog in Loki, for example
   repeated failed logins, and trigger it on purpose ([10](10-observability.md)). The range's
   [blue side](11-cyber-range.md#the-blue-side) gives you a second log source.
   [10](10-observability.md) also recommends an alert on `obs`'s disk usage. It isn't
   provisioned yet, so build it.
2. **Patching.** Find out what patches what:
   - `labgw` and `obs`: Debian's unattended upgrades;
   - Grafana, Loki and Alloy: only by hand ([10](10-observability.md));
   - the nodes: `make nodes`.

   Is any gap acceptable?
3. **Restore.** With the NAS enabled, restore the `obs` backup to a spare VMID, check it
   boots and holds its data, then delete it. Time it: that is your measured recovery time.

**Deliverable:** `study/cissp/07-operations.md`: the alert rule and its test, the patch
matrix, and the restore test record. Add a tabletop answer to "`pve1` dies on a Saturday":
what stops, what you do, in order.

**Done when:** the alert fired on the test event, and the restored VM ran.

## 8. Supply chain of the lab

**Objectives:** 8.2 Identify and apply security controls in software development
ecosystems; 8.4 Assess security impact of acquired software.

**Do:** For every third-party component, write down how its integrity is checked, or
that it isn't:

- GitHub Actions, pinned by commit SHA;
- CI tools, pinned in `.github/requirements-ci.txt`;
- Dependabot's 7-day cooldown;
- the OpenTofu provider, whose hashes are in `.terraform.lock.hcl`;
- Kali's image, signature and SHA-256 (`scripts/kali-fetch.sh`);
- OVAs, checked against their manifest, although a missing manifest is only a warning
  (`scripts/ova-unpack.sh`);
- the Debian cloud image and container template, by sha512;
- Grafana's APT repository, by its signing key.

**Deliverable:** `study/cissp/08-supply-chain.md`: component → source → integrity check →
residual risk.

**Done when:** every component has a row, and each "no check" row has a decision: add one,
or accept the risk with a reason.
