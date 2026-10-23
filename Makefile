# One entry point, run from your Mac. `make` lists the targets.
# Order for a fresh cluster: nodes -> (form the cluster) -> iac -> apply -> gateway

TOFU       ?= tofu
LAB        ?= wallix
CMD        ?= status
NAME       ?=
RELEASE    ?=
TOKEN_FILE ?= $(HOME)/.config/lab/proxmox-api-token

# The cluster starts with Proxmox's self-signed certificate (docs/07-remote-management.md).
export PROXMOX_VE_INSECURE ?= true

.DEFAULT_GOAL := help
.PHONY: help tools control tui check ping nodes routes iac init plan apply gateway obs devops qdevice remote unpack kali lab token

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{ printf "  make %-9s %s\n", $$1, $$2 }'

tools: ## Install or update the control node's tools from the Brewfile (Homebrew)
	brew bundle --file=Brewfile

control: ## SSH names for every inventory host on this machine (~/.ssh/lab.conf); needs no node
	cd ansible && ansible-playbook playbooks/control-node.yml

tui: ## Console UI: nodes, labs, guests, apps and these workflows (uv, tui/)
	uv run --project tui --locked python tui/labtui.py

check: ## Lint and validate everything offline, and test the console UI (what CI runs)
	shellcheck scripts/*.sh
	yamllint -s .
	cd ansible && ansible-playbook --syntax-check playbooks/*.yml
	cd ansible && ansible-lint --profile production
	cd terraform && $(TOFU) fmt -check -recursive && $(TOFU) init -backend=false -input=false >/dev/null && $(TOFU) validate
	uv run --project tui --locked pytest -q tui

ping: ## Check Ansible reaches every Proxmox node
	cd ansible && ansible proxmox -m ansible.builtin.ping

nodes: ## Baseline every node: repos, upgrades, tools, ZFS ARC, SSH (one node at a time)
	cd ansible && ansible-playbook playbooks/pve-postinstall.yml

routes: ## Only the nodes' routes to the lab nets (after changing gateway.nets; no upgrades)
	cd ansible && ansible-playbook playbooks/pve-postinstall.yml --tags routes

iac: ## Once per cluster: terraform@pve user, role and API token, import storage; copies the cluster CA
	cd ansible && ansible-playbook playbooks/pve-iac.yml

init: ## Initialise OpenTofu (providers from the lock file)
	cd terraform && $(TOFU) init -input=false

token:
	@test -r $(TOKEN_FILE) || { echo "No API token at $(TOKEN_FILE): run 'make iac' first."; exit 1; }

# The guests (labgw, obs) get the public keys loaded in your ssh-agent, which
# OpenTofu already uses to reach the nodes. ssh_public_keys in
# terraform/terraform.tfvars, if set, takes precedence over this variable.
AGENT_KEYS = ssh-add -L 2>/dev/null | jq -R -s -c 'split("\n") | map(select(test("^(ssh-|ecdsa-|sk-)")))'
# OpenTofu in terraform/, with the API token and those keys.
TOFU_LAB = cd terraform && PROXMOX_VE_API_TOKEN="$$(cat $(TOKEN_FILE))" TF_VAR_ssh_public_keys="$$($(AGENT_KEYS))" $(TOFU)

plan: token ## Show what OpenTofu would change on the cluster
	$(TOFU_LAB) plan

apply: token ## Build or update the Proxmox objects: SDN, pools, labgw, obs, lab VMs, NAS storage
	$(TOFU_LAB) apply

gateway: ## Configure the lab gateway (dnsmasq, nftables) after `make apply`
	cd ansible && ansible-playbook playbooks/lab-gateway.yml

obs: ## Configure the observability VM (export GRAFANA_ADMIN_PASSWORD for its first run)
	cd ansible && ansible-playbook playbooks/observability.yml

devops: ## The DevOps lab after make apply and its start: updates, k3s, Forgejo + runner (credentials → ~/.config/lab/)
	cd ansible && ansible-playbook playbooks/devops.yml

qdevice: ## Two-node quorum: prepare the nodes and the qdevice host, then run pvecm qdevice setup
	cd ansible && ansible-playbook playbooks/qdevice.yml

remote: ## Optional: Tailscale on the nodes (export TS_AUTHKEY for the first join)
	cd ansible && ansible-playbook playbooks/remote-access.yml

unpack: ## Unpack and verify an OVA for import: make unpack OVA=~/path/appliance.ova
	@test -n "$(OVA)" || { echo "usage: make unpack OVA=path/to/appliance.ova"; exit 1; }
	scripts/ova-unpack.sh "$(OVA)"

kali: ## Fetch and verify Kali's QEMU image for the cyber range: make kali [RELEASE=2026.2]
	scripts/kali-fetch.sh $(RELEASE)

lab: ## Operate a lab: make lab LAB=wallix CMD=status|start|stop|snapshots|snapshot|rollback NAME=...
	scripts/lab-ctl.sh $(LAB) $(CMD) $(NAME)
