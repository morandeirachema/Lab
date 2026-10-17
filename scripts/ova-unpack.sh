#!/usr/bin/env bash
# Unpack a VirtualBox OVA on this machine so OpenTofu can import its disks.
#
#   scripts/ova-unpack.sh path/to/appliance.ova
#
# Extracts into artifacts/ova/<name>/ (git-ignored), checks every file against
# the OVA's .mf manifest, then reads the OVF and prints the entry to paste
# under labs.<lab>.vms in config/lab.yml: CPU, memory, firmware, the MAC
# VirtualBox recorded, and each disk with its real capacity.
#
# Runs with macOS's stock bash 3.2 as well as on Linux.
set -euo pipefail

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
log()  { printf '==> %s\n' "$*" >&2; }

[[ $# -eq 1 && -f $1 ]] || { sed -n '2,11s/^# \{0,1\}//p' "$0"; exit 1; }
OVA=$1
case $OVA in *.ova|*.OVA) ;; *) die "expected a .ova file: $OVA" ;; esac

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASE=$(basename "$OVA"); BASE=${BASE%.*}
REL_DIR="artifacts/ova/$BASE"
OUT="$REPO_ROOT/$REL_DIR"

digest() {  # digest <SHA1|SHA256|SHA512> <file>
  local bits=${1#SHA}
  if command -v "sha${bits}sum" >/dev/null 2>&1; then
    "sha${bits}sum" "$2" | cut -d' ' -f1
  else
    shasum -a "$bits" "$2" | cut -d' ' -f1
  fi
}
lower() { printf '%s' "$1" | tr 'A-F' 'a-f'; }

# --- 1. Extract and verify ------------------------------------------------------
rm -rf "$OUT"
mkdir -p "$OUT"
log "Extracting $(basename "$OVA") into $REL_DIR/"
TAR_LOG=$(mktemp)
trap 'rm -f "$TAR_LOG"' EXIT
tar -xf "$OVA" -C "$OUT" 2>"$TAR_LOG" || { tail -n 3 "$TAR_LOG" >&2; die "tar could not extract $OVA"; }
if [[ -s $TAR_LOG ]]; then
  warn "tar reported problems (the manifest check below decides):"
  sort -u "$TAR_LOG" | head -n 3 >&2
fi

OVF=$(find "$OUT" -maxdepth 1 -name '*.ovf' | head -n1)
[[ -n $OVF ]] || die "no .ovf descriptor inside $OVA"

MF=$(find "$OUT" -maxdepth 1 -name '*.mf' | head -n1)
if [[ -z $MF ]]; then
  warn "no manifest (.mf) in the OVA: disk integrity NOT verified"
else
  re='^(SHA1|SHA256|SHA512) ?\(([^)]+)\) ?= ?([0-9A-Fa-f]+)'
  checked=0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line =~ $re ]] || continue
    algo=${BASH_REMATCH[1]} file=${BASH_REMATCH[2]} want=${BASH_REMATCH[3]}
    [[ -f $OUT/$file ]] || die "the manifest lists $file but the OVA does not contain it"
    got=$(digest "$algo" "$OUT/$file")
    [[ $(lower "$got") == "$(lower "$want")" ]] || die "$algo mismatch for $file: the OVA is corrupt or was modified"
    checked=$((checked + 1))
  done < "$MF"
  (( checked > 0 )) || die "the manifest $(basename "$MF") has no lines this script understands"
  log "Manifest verified: $checked file(s)"
fi

# --- 2. Read the OVF ------------------------------------------------------------
# One XML element per line, whatever the original line breaks were.
FLAT=$(tr '\r\n\t' '   ' < "$OVF" | tr '<' '\n')

attr() {  # attr <element line> <attribute>
  printf '%s\n' "$1" | sed -nE "s/.*[ :]$2=\"([^\"]*)\".*/\1/p" | head -n1
}

read -r CPUS MEM_MIB <<EOF
$(printf '%s\n' "$FLAT" | awk '
  /^(ovf:)?Item[ >]/                 { rt = ""; q = ""; unit = "" }
  /^rasd:ResourceType>/              { sub(/^rasd:ResourceType>/, "");    rt = $0 + 0 }
  /^rasd:VirtualQuantity>/           { sub(/^rasd:VirtualQuantity>/, ""); q = $0 + 0 }
  /^rasd:AllocationUnits>/           { sub(/^rasd:AllocationUnits>/, ""); unit = $0 }
  /^\/(ovf:)?Item>/ {
    if (rt == 3) cpu = q
    if (rt == 4) { mem = q; if (unit ~ /2\^30|GigaBytes/) mem = q * 1024 }
  }
  END { print (cpu ? cpu : "?") " " (mem ? mem : "?") }')
EOF

NAME=$(printf '%s\n' "$FLAT" | sed -n 's/^Name>\(.*\)$/\1/p' | head -n1 | sed 's/ *$//')
NAME=$(printf '%s' "${NAME:-$BASE}" | tr -c 'A-Za-z0-9.-' '-' | sed -E 's/^-+//; s/-+$//')

if printf '%s\n' "$FLAT" | grep -Eqi '^(vbox:)?Firmware[^>]*type="EFI|vmw:value="efi"'; then
  FIRMWARE=efi
else
  FIRMWARE=bios
fi

MAC=$(printf '%s\n' "$FLAT" | grep -oE 'MACAddress="[0-9A-Fa-f]{12}"' | head -n1 \
        | grep -oE '[0-9A-Fa-f]{12}' | sed -E 's/(..)(..)(..)(..)(..)(..)/\1:\2:\3:\4:\5:\6/' || true)

# Disks: each <Disk> names a <File> by ovf:fileRef; capacity is in bytes
# unless ovf:capacityAllocationUnits says "byte * 2^N".
DISK_YAML=""
n=0
while IFS= read -r disk; do
  [[ -n $disk ]] || continue
  ref=$(attr "$disk" fileRef)
  cap=$(attr "$disk" capacity)
  units=$(attr "$disk" capacityAllocationUnits)
  file_el=$(printf '%s\n' "$FLAT" | grep -E "^(ovf:)?File .*ovf:id=\"$ref\"" | head -n1)
  href=$(attr "$file_el" href)
  [[ -n $href && -f $OUT/$href ]] || die "disk $ref points at '$href', which is not in the OVA"
  [[ -z $(attr "$file_el" compression) ]] || die "$href is compressed inside the OVF; not supported"
  case $units in
    ""|byte) bytes=$cap ;;
    *"2^20"*) bytes=$((cap * 1048576)) ;;
    *"2^30"*) bytes=$((cap * 1073741824)) ;;
    *) die "unknown capacity unit '$units' for $href" ;;
  esac
  gib=$(( (bytes + 1073741823) / 1073741824 ))
  DISK_YAML+="          - image: $REL_DIR/$href"$'\n'"            size_gb: $gib"$'\n'
  n=$((n + 1))
done <<EOF
$(printf '%s\n' "$FLAT" | grep -E '^(ovf:)?Disk ')
EOF
(( n > 0 )) || die "the OVF declares no disks"

MAC_LINE=""
[[ -n $MAC ]] && MAC_LINE=$'\n'"        # mac: $MAC     # the MAC VirtualBox recorded; uncomment to keep it"

# --- 3. Report ------------------------------------------------------------------
log "Unpacked $(basename "$OVA"): $NAME, $CPUS vCPU, $MEM_MIB MiB, $FIRMWARE, $n disk(s)"
[[ $FIRMWARE == efi ]] && log "EFI guest: keep firmware: efi; Windows 11 / Server 2025 may also need tpm: true"
cat <<EOF

# Add under labs.<lab>.vms in config/lab.yml, then fill in vmid, node and vnet:
      - vmid: <free id in the lab's range>
        name: $NAME
        node: <pve1|pve2>
        memory: $MEM_MIB
        cores: $CPUS
        os: l26               # win10 for Windows 10 / Server 2016-2022, win11 for 11 / 2025
        firmware: $FIRMWARE
        vnet: <pam|devops|cyber>${MAC_LINE}
        disks:
${DISK_YAML%$'\n'}
EOF
