#!/usr/bin/env bash
# Import every OVA that a lab file assigns to this node.
#
#   deploy-lab.sh labs/pam/vms.tsv              # rows whose node column is this host
#   deploy-lab.sh labs/pam/vms.tsv --any-node   # every row, imported on this host
#   DRY_RUN=1 deploy-lab.sh labs/pam/vms.tsv    # show the qm commands only
#
# Rows whose VMID already exists are skipped, so it is safe to re-run.
set -euo pipefail

# shellcheck source=scripts/pve/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

usage() { sed -n '2,9s/^# \{0,1\}//p' "$0"; }

LABFILE=${1:-}
[[ -n $LABFILE && -f $LABFILE ]] || { usage; exit 1; }
ANY_NODE=0
case ${2:-} in
  "") ;;
  --any-node) ANY_NODE=1 ;;
  *) die "unknown option: $2" ;;
esac

require_root
require_cmd pvesh hostname
LAB=$(basename "$(cd "$(dirname "$LABFILE")" && pwd)")  # labs/pam/vms.tsv -> pam
HERE=$(hostname -s)
IMPORT="$(dirname "${BASH_SOURCE[0]}")/import-ova.sh"

done_ids=() failed_ids=()
while read -r vmid name node ova bridge memory cores ostype flags _ <&3; do
  [[ -z ${vmid:-} || $vmid == \#* ]] && continue
  [[ -n ${flags:-} ]] || die "row $vmid has fewer than 9 columns"

  if [[ $node != "$HERE" && $ANY_NODE -eq 0 ]]; then
    log "skip $vmid $name: assigned to $node"
    continue
  fi
  if [[ $ova == - ]]; then
    log "skip $vmid $name: not an OVA row"
    continue
  fi
  if vmid_in_use "$vmid"; then
    log "skip $vmid $name: already exists"
    continue
  fi

  [[ $ova == /* ]] || ova="$LAB_OVA_DIR/$ova"
  if [[ ! -f $ova ]]; then
    warn "$vmid $name: $ova is not on $HERE; copy it there first"
    failed_ids+=("$vmid")
    continue
  fi

  args=(-i "$vmid" -f "$ova" -n "$name" -b "$bridge" -T "lab;$LAB")
  [[ $memory != - ]] && args+=(-m "$memory")
  [[ $cores  != - ]] && args+=(-c "$cores")
  [[ $ostype != - ]] && args+=(-o "$ostype")
  snapshot=${LAB_IMPORT_SNAPSHOT:-imported}
  IFS=, read -r -a row_flags <<<"$flags"
  for f in "${row_flags[@]}"; do
    case $f in
      -|"") ;;
      efi|bios) args+=(-F "$f") ;;
      tpm) args+=(-t) ;;
      keepmac) args+=(-k) ;;
      nosnap) snapshot="" ;;
      sata|ide|scsi) args+=(-d "$f") ;;
      e1000|e1000e|virtio|vmxnet3) args+=(-N "$f") ;;
      *) die "row $vmid: unknown flag '$f'" ;;
    esac
  done
  [[ -n $snapshot ]] && args+=(-S "$snapshot")

  log "Importing $vmid $name from $(basename "$ova")"
  if bash "$IMPORT" "${args[@]}"; then
    done_ids+=("$vmid")
  else
    failed_ids+=("$vmid")
  fi
done 3< "$LABFILE"

log "Lab '$LAB' on $HERE: imported ${#done_ids[@]} [${done_ids[*]:-}], failed ${#failed_ids[@]} [${failed_ids[*]:-}]"
(( ${#failed_ids[@]} == 0 ))
