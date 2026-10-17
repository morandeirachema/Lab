#!/usr/bin/env bash
# Operate a whole lab from any node of the cluster.
#
#   lab-ctl.sh LABFILE status           state of every guest in the lab
#   lab-ctl.sh LABFILE start            start top to bottom, LAB_START_DELAY s apart
#   lab-ctl.sh LABFILE stop             clean shutdown bottom to top (forced after 180 s)
#   lab-ctl.sh LABFILE snapshot NAME    snapshot every guest (stop the lab first)
#   lab-ctl.sh LABFILE rollback NAME    roll every guest back to NAME
#   lab-ctl.sh LABFILE snapshots        list each guest's snapshots
#
# Guests are found wherever they run now, so migrating one does not break it.
# Works for VMs and containers alike.
set -euo pipefail

# shellcheck source=scripts/pve/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

usage() { sed -n '2,13s/^# \{0,1\}//p' "$0"; }

LABFILE=${1:-} CMD=${2:-} ARG=${3:-}
[[ -n $LABFILE && -f $LABFILE && -n $CMD ]] || { usage; exit 1; }
case $CMD in
  status|start|stop|snapshots) ;;
  snapshot|rollback) [[ $ARG =~ ^[A-Za-z][A-Za-z0-9_-]{1,39}$ ]] || die "$CMD needs a snapshot name (letter first, then letters, digits, _ or -)" ;;
  *) usage; exit 1 ;;
esac

require_root
require_cmd pvesh jq

IDS=() NAMES=()
while read -r vmid name _ <&3; do
  [[ -z ${vmid:-} || $vmid == \#* ]] && continue
  IDS+=("$vmid") NAMES+=("$name")
done 3< "$LABFILE"
(( ${#IDS[@]} > 0 )) || die "no guests in $LABFILE"

RESOURCES=$(pvesh get /cluster/resources --type vm --output-format json)

# "<node> <qemu|lxc>/<vmid> <status>" for a VMID, empty if it does not exist.
guest() {
  jq -r --argjson id "$1" '.[] | select(.vmid == $id) | "\(.node) \(.id) \(.status)"' <<<"$RESOURCES"
}

# Some pvesh calls return a task ID (UPID); wait for it and fail if the task did.
wait_task() {
  local node=$1 out=$2 upid st
  upid=$(grep -oE 'UPID:[^[:space:]"]+' <<<"$out" | head -n1 || true)
  [[ -n $upid ]] || return 0
  while :; do
    st=$(pvesh get "/nodes/$node/tasks/$upid/status" --output-format json)
    [[ $(jq -r .status <<<"$st") == stopped ]] && break
    sleep 2
  done
  [[ $(jq -r .exitstatus <<<"$st") == OK ]] || { warn "task failed: $(jq -r .exitstatus <<<"$st")"; return 1; }
}

api() {  # api <node> <create|get> <path> [args...]
  local node=$1 verb=$2 path=$3 out
  shift 3
  out=$(pvesh "$verb" "$path" "$@" --output-format json)
  wait_task "$node" "$out"
}

order=("${!IDS[@]}")
if [[ $CMD == stop ]]; then
  order=()
  for (( i = ${#IDS[@]} - 1; i >= 0; i-- )); do order+=("$i"); done
fi

[[ $CMD == status ]] && printf '%-6s %-20s %-6s %-10s\n' VMID NAME NODE STATUS
rc=0 n=0
for i in "${order[@]}"; do
  id=${IDS[$i]} name=${NAMES[$i]} n=$((n + 1))
  info=$(guest "$id")
  if [[ -z $info ]]; then
    if [[ $CMD == status ]]; then
      printf '%-6s %-20s %-6s %-10s\n' "$id" "$name" - missing
    else
      warn "$id $name does not exist; deploy it first"
    fi
    continue
  fi
  read -r node path status <<<"$info"
  base="/nodes/$node/$path"

  case $CMD in
    status)
      printf '%-6s %-20s %-6s %-10s\n' "$id" "$name" "$node" "$status"
      ;;
    start)
      if [[ $status == running ]]; then log "$id $name already running"; continue; fi
      log "start $id $name on $node"
      api "$node" create "$base/status/start" || rc=1
      if (( n < ${#IDS[@]} )); then sleep "${LAB_START_DELAY:-20}"; fi
      ;;
    stop)
      if [[ $status != running ]]; then log "$id $name already $status"; continue; fi
      log "shutdown $id $name on $node"
      api "$node" create "$base/status/shutdown" --timeout 180 --forceStop 1 || rc=1
      ;;
    snapshot)
      [[ $status == running ]] && warn "$id $name is running; the snapshot is only crash-consistent"
      log "snapshot $id $name -> $ARG"
      api "$node" create "$base/snapshot" --snapname "$ARG" --description "lab-ctl $(date +%F)" || rc=1
      ;;
    rollback)
      log "rollback $id $name -> $ARG"
      api "$node" create "$base/snapshot/$ARG/rollback" || rc=1
      ;;
    snapshots)
      snaps=$(pvesh get "$base/snapshot" --output-format json | jq -r '[.[] | select(.name != "current") | .name] | join(", ")')
      printf '%-6s %-20s %s\n' "$id" "$name" "${snaps:-(none)}"
      ;;
  esac
done
exit "$rc"
