# shellcheck shell=bash
# Shared helpers for scripts/pve/*.sh — source it, don't run it.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "run this as root on a Proxmox VE node"
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing command: $c"
  done
}

# config/lab.env, then the optional git-ignored config/lab.local.env.
load_config() {
  local f
  for f in "$REPO_ROOT/config/lab.env" "$REPO_ROOT/config/lab.local.env"; do
    # shellcheck source=/dev/null
    [[ -f $f ]] && source "$f"
  done
  return 0
}

# True when the VMID is taken by any VM or container anywhere in the cluster.
vmid_in_use() {
  ! pvesh get /cluster/nextid --vmid "$1" >/dev/null 2>&1
}

# Print instead of execute when DRY_RUN=1.
run() {
  if [[ ${DRY_RUN:-0} == 1 ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}
