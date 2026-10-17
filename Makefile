# One entry point, run from your Mac. `make` lists the targets.
# Order for a fresh cluster: nodes -> (form the cluster) -> iac -> apply -> gateway

TOFU       ?= tofu
LAB        ?= wallix
CMD        ?= status
NAME       ?=
TOKEN_FILE ?= $(HOME)/.config/lab/proxmox-api-token

# The cluster starts with Proxmox's self-signed certificate (docs/07-remote-management.md).
export PROXMOX_VE_INSECURE ?= true

.DEFAULT_GOAL := help
.PHONY: help check ping nodes iac init plan apply gateway obs remote unpack lab token

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{ printf "  make %-9s %s\n", $$1, $$2 }'

check: ## Lint and validate everything offline (what CI runs)
	shellcheck scripts/*.sh
	yamllint -s .
	cd ansible && ansible-playbook --syntax-check playbooks/*.yml
	cd terraform && $(TOFU) fmt -check -recursive && $(TOFU) init -backend=false -input=false >/dev/null && $(TOFU) validate

ping: ## Check Ansible reaches every Proxmox node
	cd ansible && ansible proxmox -m ansible.builtin.ping

nodes: ## Baseline every node: repos, upgrades, tools, ZFS ARC, SSH (one node at a time)
	cd ansible && ansible-playbook playbooks/pve-postinstall.yml

iac: ## Once per cluster: terraform@pve user, role and API token, import storage
	cd ansible && ansible-playbook playbooks/pve-iac.yml

init: ## Initialise OpenTofu (providers from the lock file)
	cd terraform && $(TOFU) init -input=false

token:
	@test -r $(TOKEN_FILE) || { echo "No API token at $(TOKEN_FILE): run 'make iac' first."; exit 1; }

plan: token ## Show what OpenTofu would change on the cluster
	cd terraform && PROXMOX_VE_API_TOKEN="$$(cat $(TOKEN_FILE))" $(TOFU) plan

apply: token ## Build or update SDN, pools, the gateway container and the lab VMs
	cd terraform && PROXMOX_VE_API_TOKEN="$$(cat $(TOKEN_FILE))" $(TOFU) apply

gateway: ## Configure the lab gateway (dnsmasq, nftables) after `make apply`
	cd ansible && ansible-playbook playbooks/lab-gateway.yml

obs: ## Configure the observability VM (export GRAFANA_ADMIN_PASSWORD for its first run)
	cd ansible && ansible-playbook playbooks/observability.yml

remote: ## Optional: Tailscale on the nodes (export TS_AUTHKEY for the first join)
	cd ansible && ansible-playbook playbooks/remote-access.yml

unpack: ## Unpack and verify an OVA for import: make unpack OVA=~/path/appliance.ova
	@test -n "$(OVA)" || { echo "usage: make unpack OVA=path/to/appliance.ova"; exit 1; }
	scripts/ova-unpack.sh "$(OVA)"

lab: ## Operate a lab: make lab LAB=wallix CMD=status|start|stop|snapshots|snapshot|rollback NAME=...
	scripts/lab-ctl.sh $(LAB) $(CMD) $(NAME)
