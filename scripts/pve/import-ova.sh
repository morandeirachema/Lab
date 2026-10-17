#!/usr/bin/env bash
# Import a VirtualBox OVA (or an already-extracted OVF) as a Proxmox VE VM.
#
# Run as root on the node that will host the VM. The VM is assembled with
# `qm create` + `import-from` instead of `qm importovf`, so every appliance
# comes out the same way: the CPU/RAM you ask for, disks on the bus the guest
# already has drivers for (SATA by default), one NIC on the bridge/vnet you
# name, and the firmware (BIOS or EFI) the OVF records.
set -euo pipefail

# shellcheck source=scripts/pve/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

usage() {
  cat <<EOF
Usage: $(basename "$0") -i VMID -f FILE.ova|FILE.ovf [options]

  -i VMID      VM ID to create (must be free cluster-wide)
  -f FILE      .ova archive, or an extracted .ovf next to its disks
  -n NAME      VM name                     (default: <Name> in the OVF)
  -s STORAGE   storage for the disks       (default: ${LAB_STORAGE:-local-zfs})
  -b BRIDGE    bridge or SDN vnet for net0 (default: vmbr0)
  -m MIB       memory in MiB               (default: value in the OVF)
  -c CORES     vCPU cores                  (default: value in the OVF)
  -o OSTYPE    l26, win10, win11, other... (default: l26)
  -d BUS       sata | ide | scsi           (default: ${LAB_DISK_BUS:-sata})
  -N MODEL     e1000 | e1000e | virtio | vmxnet3 (default: ${LAB_NIC_MODEL:-e1000})
  -F FIRMWARE  auto | bios | efi           (default: auto, read from the OVF)
  -t           add a TPM 2.0 state volume (Windows 11 / Server 2025)
  -k           keep the MAC address recorded in the OVF
  -S SNAPNAME  snapshot the VM right after the import
  -T TAGS      semicolon-separated tags    (default: imported)
  -h           this help

Environment: DRY_RUN=1 prints the qm commands instead of running them;
KEEP_WORK=1 keeps the extracted OVA under ${LAB_WORK_DIR:-/var/lib/vz/import/.work}.
EOF
}

VMID="" FILE="" NAME="" STORAGE="${LAB_STORAGE:-local-zfs}" BRIDGE="vmbr0"
MEMORY="" CORES="" OSTYPE="l26" BUS="${LAB_DISK_BUS:-sata}" NIC="${LAB_NIC_MODEL:-e1000}"
FIRMWARE="auto" TPM=0 KEEP_MAC=0 SNAPSHOT="" TAGS="imported"
WORK_ROOT="${LAB_WORK_DIR:-/var/lib/vz/import/.work}"

while getopts ':i:f:n:s:b:m:c:o:d:N:F:tkS:T:h' opt; do
  case $opt in
    i) VMID=$OPTARG ;;
    f) FILE=$OPTARG ;;
    n) NAME=$OPTARG ;;
    s) STORAGE=$OPTARG ;;
    b) BRIDGE=$OPTARG ;;
    m) MEMORY=$OPTARG ;;
    c) CORES=$OPTARG ;;
    o) OSTYPE=$OPTARG ;;
    d) BUS=$OPTARG ;;
    N) NIC=$OPTARG ;;
    F) FIRMWARE=$OPTARG ;;
    t) TPM=1 ;;
    k) KEEP_MAC=1 ;;
    S) SNAPSHOT=$OPTARG ;;
    T) TAGS=$OPTARG ;;
    h) usage; exit 0 ;;
    :) die "option -$OPTARG needs a value (see -h)" ;;
    *) die "unknown option -$OPTARG (see -h)" ;;
  esac
done

[[ $VMID =~ ^[0-9]+$ ]] || die "-i VMID is required and must be numeric"
[[ -n $FILE && -f $FILE ]] || die "-f must name an existing .ova or .ovf file"
case $BUS in
  sata) max_disks=6 ;;
  ide)  max_disks=4 ;;
  scsi) max_disks=31 ;;
  *) die "-d must be sata, ide or scsi" ;;
esac
case $FIRMWARE in auto|bios|efi) ;; *) die "-F must be auto, bios or efi" ;; esac
[[ -z $MEMORY || $MEMORY =~ ^[0-9]+$ ]] || die "-m must be MiB, e.g. 2048"
[[ -z $CORES || $CORES =~ ^[0-9]+$ ]] || die "-c must be a number"

require_root
require_cmd qm pvesh tar awk sed grep
vmid_in_use "$VMID" && die "VMID $VMID is already in use in this cluster"

file_size() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

# Print "<cpus> <memory MiB>" from the OVF's VirtualHardwareSection; either
# may be empty. ResourceType 3 = processor, 4 = memory (DMTF CIM).
ovf_hardware() {
  awk '
    /<(ovf:)?Item[ >]/ { rt = ""; q = ""; unit = "" }
    match($0, /ResourceType>[0-9]+</)    { rt   = substr($0, RSTART + 13, RLENGTH - 14) }
    match($0, /VirtualQuantity>[0-9]+</) { q    = substr($0, RSTART + 16, RLENGTH - 17) }
    match($0, /AllocationUnits>[^<]+</)  { unit = substr($0, RSTART + 16, RLENGTH - 17) }
    /<\/(ovf:)?Item>/ {
      if (rt == "3") cpu = q
      if (rt == "4") { mem = q; if (unit ~ /2\^30|GigaBytes/) mem = q * 1024 }
    }
    END { print cpu " " mem }
  ' "$1"
}

# Check every file listed in the OVA manifest (.mf). Accepts both
# "SHA256(file)= digest" and "SHA256 (file) = digest".
verify_manifest() {
  local dir=$1 mf line algo file digest actual
  mf=$(find "$dir" -maxdepth 1 -name '*.mf' | head -n1)
  if [[ -z $mf ]]; then
    warn "no manifest (.mf) in the OVA; disk integrity not verified"
    return 0
  fi
  local re='^(SHA1|SHA256|SHA512) ?\(([^)]+)\) ?= ?([0-9A-Fa-f]+)'
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line =~ $re ]] || continue
    algo=${BASH_REMATCH[1]} file=${BASH_REMATCH[2]} digest=${BASH_REMATCH[3]}
    [[ -f $dir/$file ]] || die "manifest lists $file but the OVA does not contain it"
    case $algo in
      SHA1)   actual=$(sha1sum   "$dir/$file" | cut -d' ' -f1) ;;
      SHA256) actual=$(sha256sum "$dir/$file" | cut -d' ' -f1) ;;
      SHA512) actual=$(sha512sum "$dir/$file" | cut -d' ' -f1) ;;
    esac
    [[ ${actual,,} == "${digest,,}" ]] || die "$algo mismatch for $file: the OVA is corrupt or was modified"
  done < "$mf"
  log "Manifest verified ($(basename "$mf"))"
}

WORK="" CREATED=0
cleanup() {
  local rc=$?
  if [[ $rc -ne 0 && $CREATED -eq 1 && ${DRY_RUN:-0} != 1 ]]; then
    warn "import failed; removing the half-built VM $VMID"
    qm destroy "$VMID" --purge 1 --destroy-unreferenced-disks 1 >/dev/null 2>&1 \
      || warn "could not remove VM $VMID; remove it by hand"
  fi
  if [[ -n $WORK && ${KEEP_WORK:-0} != 1 ]]; then
    rm -rf "$WORK"
  fi
  exit "$rc"
}
trap cleanup EXIT

# --- 1. Unpack -----------------------------------------------------------
case $FILE in
  *.ova|*.OVA)
    mkdir -p "$WORK_ROOT"
    need_kb=$(( $(file_size "$FILE") / 1024 ))
    free_kb=$(df -Pk "$WORK_ROOT" | awk 'NR == 2 { print $4 }')
    (( free_kb > need_kb )) || die "$WORK_ROOT has ${free_kb} KiB free; extracting needs ${need_kb} KiB"
    WORK=$(mktemp -d "$WORK_ROOT/$VMID.XXXXXX")
    log "Extracting $(basename "$FILE") into $WORK"
    tar -xf "$FILE" -C "$WORK"
    OVF=$(find "$WORK" -maxdepth 1 -name '*.ovf' | head -n1)
    [[ -n $OVF ]] || die "no .ovf descriptor inside $FILE"
    verify_manifest "$WORK"
    ;;
  *.ovf|*.OVF)
    OVF=$FILE
    ;;
  *)
    die "expected a .ova or .ovf file, got: $FILE"
    ;;
esac
OVF_DIR=$(cd "$(dirname "$OVF")" && pwd)

# --- 2. Read the descriptor -------------------------------------------------
DISKS=()
while IFS= read -r href; do
  DISKS+=("$href")
done < <(grep -oE 'ovf:href="[^"]+"' "$OVF" \
           | sed -E 's/^ovf:href="(.*)"$/\1/' \
           | grep -iE '\.(vmdk|vhd|vhdx|qcow2|img|raw)$' || true)
(( ${#DISKS[@]} > 0 )) || die "the OVF references no disk images"
(( ${#DISKS[@]} <= max_disks )) || die "${#DISKS[@]} disks do not fit on the $BUS bus (max $max_disks)"

read -r ovf_cpus ovf_mem <<<"$(ovf_hardware "$OVF")" || true
CORES=${CORES:-${ovf_cpus:-2}}
MEMORY=${MEMORY:-${ovf_mem:-2048}}

if [[ -z $NAME ]]; then
  NAME=$(sed -n 's:.*<Name>\(.*\)</Name>.*:\1:p' "$OVF" | head -n1)
  NAME=${NAME:-$(basename "${FILE%.*}")}
fi
NAME=$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9.-' '-' | sed -E 's/^-+//; s/-+$//')

if [[ $FIRMWARE == auto ]]; then
  # VirtualBox: <Firmware type="EFI"/> in its vbox:Machine block;
  # VMware: vmw:key="firmware" vmw:value="efi".
  if grep -Eqi '<(vbox:)?Firmware[^>]*type="EFI|vmw:value="efi"' "$OVF"; then
    FIRMWARE=efi
  else
    FIRMWARE=bios
  fi
fi

MAC=""
if (( KEEP_MAC )); then
  MAC=$(grep -oE 'MACAddress="[0-9A-Fa-f]{12}"' "$OVF" | head -n1 | grep -oE '[0-9A-Fa-f]{12}' \
          | sed -E 's/(..)(..)(..)(..)(..)(..)/\1:\2:\3:\4:\5:\6/' | tr 'a-f' 'A-F' || true)
  [[ -n $MAC ]] || warn "-k given but the OVF records no MAC address; Proxmox will generate one"
fi

# --- 3. Build the VM ------------------------------------------------------------
net0="model=${NIC},bridge=${BRIDGE}"
[[ -n $MAC ]] && net0+=",macaddr=${MAC}"
# A virtio NIC can take the vnet's MTU (1450 on VXLAN); emulated NICs cannot.
[[ ${LAB_SDN_TYPE:-vlan} == vxlan && $NIC == virtio ]] && net0+=",mtu=1"

desc="Imported from $(basename "$FILE") on $(date +%F) by scripts/pve/import-ova.sh"
create_args=(
  --name "$NAME" --ostype "$OSTYPE" --memory "$MEMORY" --cores "$CORES"
  --cpu x86-64-v2-AES --scsihw virtio-scsi-single
  --net0 "$net0" --tags "$TAGS" --description "$desc"
)
if [[ $FIRMWARE == efi ]]; then
  create_args+=(--bios ovmf --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=0")
fi
if (( TPM )); then
  create_args+=(--tpmstate0 "${STORAGE}:1,version=v2.0")
fi

log "Creating VM $VMID '$NAME': $CORES vCPU, $MEMORY MiB, $FIRMWARE, ${#DISKS[@]} disk(s) on $BUS, net0 $net0"
run qm create "$VMID" "${create_args[@]}"
CREATED=1

i=0
for disk in "${DISKS[@]}"; do
  src="$OVF_DIR/$disk"
  [[ -f $src ]] || die "the OVF lists $disk but it is not next to the descriptor"
  opts="${STORAGE}:0,import-from=${src}"
  [[ $BUS != ide ]] && opts+=",discard=on"
  log "Importing disk $((i + 1))/${#DISKS[@]}: $disk -> ${BUS}${i}"
  run qm set "$VMID" "--${BUS}${i}" "$opts"
  i=$((i + 1))
done
run qm set "$VMID" --boot "order=${BUS}0"

if [[ -n $SNAPSHOT ]]; then
  log "Snapshot '$SNAPSHOT'"
  run qm snapshot "$VMID" "$SNAPSHOT" --description "Pristine import of $(basename "$FILE")"
fi

CREATED=0  # success: the cleanup trap must not destroy it
log "VM $VMID '$NAME' is ready (not started). Review it with: qm config $VMID"
