#!/usr/bin/env bash
# Operate a lab through the Proxmox API, from this machine.
#
#   scripts/lab-ctl.sh LAB status          every guest tagged LAB: node, type, state
#   scripts/lab-ctl.sh LAB start           start in VMID order, LAB_START_DELAY s apart (default 20)
#   scripts/lab-ctl.sh LAB stop            clean shutdown in reverse VMID order, forced after 180 s
#   scripts/lab-ctl.sh LAB snapshot NAME   snapshot every guest (stop the lab first for a clean state)
#   scripts/lab-ctl.sh LAB rollback NAME   roll every guest back to NAME (on ZFS only the newest works)
#   scripts/lab-ctl.sh LAB snapshots       list each guest's snapshots
#
# LAB is a lab name from config/lab.yml (OpenTofu tags its guests with it).
# Guests are found wherever they run now, so migrations do not matter.
#
# Environment (all optional):
#   PROXMOX_VE_ENDPOINT   default https://<first host in ansible/inventory/hosts.yml>:8006/
#   PROXMOX_VE_API_TOKEN  default: the file ansible/playbooks/pve-iac.yml wrote,
#                         ~/.config/lab/proxmox-api-token
#   PROXMOX_VE_CACERT     the cluster CA (a copy of /etc/pve/pve-root-ca.pem) to verify against
#   PROXMOX_VE_INSECURE   true to accept the cluster's certificate unverified (ignored with CACERT)
#   LAB_TASK_TIMEOUT      seconds to wait for each Proxmox task (default 600)
#
# Needs curl and jq. Runs with macOS's bash 3.2.
set -euo pipefail

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
log()  { printf '==> %s\n' "$*"; }
usage() { sed -n '2,23s/^# \{0,1\}//p' "$0"; exit 1; }

LAB=${1:-} CMD=${2:-} ARG=${3:-}
[[ -n $LAB && -n $CMD ]] || usage
case $CMD in
  status|start|stop|snapshots) ;;
  snapshot|rollback)
    [[ $ARG =~ ^[A-Za-z][A-Za-z0-9_-]{1,39}$ ]] \
      || die "$CMD needs a snapshot name: a letter, then letters, digits, _ or - (2-40 characters)" ;;
  *) usage ;;
esac
for c in curl jq; do command -v "$c" >/dev/null || die "missing command: $c"; done

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [[ -z ${PROXMOX_VE_ENDPOINT:-} ]]; then
  first=$(awk '/ansible_host:/ { print $2; exit }' "$REPO_ROOT/ansible/inventory/hosts.yml")
  PROXMOX_VE_ENDPOINT="https://$first:8006/"
fi
if [[ -z ${PROXMOX_VE_API_TOKEN:-} ]]; then
  token_file="$HOME/.config/lab/proxmox-api-token"
  [[ -r $token_file ]] || die "set PROXMOX_VE_API_TOKEN or run ansible/playbooks/pve-iac.yml to create $token_file"
  PROXMOX_VE_API_TOKEN=$(tr -d '\n' < "$token_file")
fi
TLS=()
if [[ -n ${PROXMOX_VE_CACERT:-} ]]; then
  [[ -r $PROXMOX_VE_CACERT ]] || die "PROXMOX_VE_CACERT: cannot read $PROXMOX_VE_CACERT"
  TLS=(--cacert "$PROXMOX_VE_CACERT")
elif [[ ${PROXMOX_VE_INSECURE:-false} == true ]]; then
  TLS=(--insecure)
fi

api() {  # api GET|POST <path> [curl --data... args]
  local method=$1 path=$2 out
  shift 2
  # The token goes in through curl's -H @file form, so it never shows up in
  # the process list the way a -H argument would.
  out=$(curl -sS --fail-with-body ${TLS[@]+"${TLS[@]}"} -X "$method" \
          -H @<(printf 'Authorization: PVEAPIToken=%s\n' "$PROXMOX_VE_API_TOKEN") \
          "${PROXMOX_VE_ENDPOINT%/}/api2/json$path" "$@") \
    || die "$method $path: $(jq -r '.message // .errors // .' <<<"$out" 2>/dev/null || printf '%s' "$out")"
  jq -c '.data' <<<"$out" 2>/dev/null || die "$method $path: the API returned something that is not JSON"
}

# POSTs that start a task return its UPID; wait for it (at most
# LAB_TASK_TIMEOUT seconds, default 600) and report failure.
wait_task() {
  local node=$1 upid=$2 st status exitstatus waited=0
  local limit=${LAB_TASK_TIMEOUT:-600}
  [[ $upid == UPID:* ]] || return 0
  upid=$(jq -rn --arg u "$upid" '$u | @uri') || return 1
  while :; do
    st=$(api GET "/nodes/$node/tasks/$upid/status") || return 1
    status=$(jq -r '.status // empty' <<<"$st") || return 1
    [[ $status == stopped ]] && break
    if (( waited >= limit )); then
      warn "task still '${status:-unknown}' after ${limit}s; giving up waiting (it may still finish)"
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
  exitstatus=$(jq -r '.exitstatus // empty' <<<"$st") || return 1
  [[ $exitstatus == OK ]] || { warn "task failed: ${exitstatus:-no exit status}"; return 1; }
}

task() {  # task <node> <path> [curl --data... args]
  local node=$1 path=$2 out upid
  shift 2
  out=$(api POST "$path" "$@") || return 1
  upid=$(jq -r '. // empty' <<<"$out") || return 1
  wait_task "$node" "$upid"
}

# "<vmid> <node> <qemu|lxc> <status> <name>" per guest tagged $LAB, by VMID.
GUESTS=$(api GET "/cluster/resources?type=vm" | jq -r --arg lab "$LAB" '
  [ .[] | select(((.tags // "") | split(";") | index($lab)) != null) ]
  | sort_by(.vmid)[] | "\(.vmid) \(.node) \(.type) \(.status) \(.name // "-")"')
[[ -n $GUESTS ]] || die "no guests tagged '$LAB' (is the lab deployed? see terraform/)"
[[ $CMD == stop ]] && GUESTS=$(printf '%s\n' "$GUESTS" | sort -rn)
COUNT=$(printf '%s\n' "$GUESTS" | wc -l | tr -d ' ')

[[ $CMD == status ]] && printf '%-6s %-20s %-6s %-5s %s\n' VMID NAME NODE TYPE STATUS
rc=0 n=0
while read -r vmid node type status name <&3; do
  n=$((n + 1))
  base="/nodes/$node/$type/$vmid"
  case $CMD in
    status)
      printf '%-6s %-20s %-6s %-5s %s\n' "$vmid" "$name" "$node" "$type" "$status"
      ;;
    start)
      if [[ $status == running ]]; then log "$vmid $name already running"; continue; fi
      log "start $vmid $name on $node"
      task "$node" "$base/status/start" || rc=1
      if (( n < COUNT )); then sleep "${LAB_START_DELAY:-20}"; fi
      ;;
    stop)
      if [[ $status != running ]]; then log "$vmid $name already $status"; continue; fi
      log "shutdown $vmid $name on $node"
      task "$node" "$base/status/shutdown" --data timeout=180 --data forceStop=1 || rc=1
      ;;
    snapshot)
      [[ $status == running ]] && warn "$vmid $name is running: the snapshot is only crash-consistent"
      log "snapshot $vmid $name -> $ARG"
      task "$node" "$base/snapshot" --data-urlencode "snapname=$ARG" \
        --data-urlencode "description=lab-ctl $(date +%F)" || rc=1
      ;;
    rollback)
      log "rollback $vmid $name -> $ARG"
      task "$node" "$base/snapshot/$ARG/rollback" || rc=1
      ;;
    snapshots)
      snaps=$(api GET "$base/snapshot" | jq -r '[.[] | select(.name != "current") | .name] | join(", ")')
      printf '%-6s %-20s %s\n' "$vmid" "$name" "${snaps:-(none)}"
      ;;
    *) die "unreachable: unknown command $CMD" ;;
  esac
done 3<<EOF
$GUESTS
EOF
exit "$rc"
