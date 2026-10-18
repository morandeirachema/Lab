#!/usr/bin/env bash
# Fetch Kali Linux's prebuilt QEMU image on this machine, for the cyber range.
#
#   scripts/kali-fetch.sh [RELEASE]      RELEASE like 2026.2; default: the current one
#
# Checks the release's SHA256SUMS against its signature by Kali's archive key
# (fingerprint pinned below), downloads the QEMU .7z and checks its SHA-256,
# extracts the one .qcow2 inside into artifacts/kali/ (git-ignored), reads the
# disk's virtual size from the qcow2 header and prints the entry to paste under
# labs.cyber.vms in config/lab.yml. A re-run resumes or reuses the download.
#
# Needs curl, gpg and 7-Zip (7zz or 7z): brew install gnupg sevenzip
# Runs with macOS's stock bash 3.2 as well as on Linux.
set -euo pipefail

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log()  { printf '==> %s\n' "$*" >&2; }

# Kali's signing key, as kali.org/docs/introduction/download-official-kali-linux-images/ gives it.
KALI_KEY_URL=https://archive.kali.org/archive-key.asc
KALI_KEY_FPR=827C8569F2518CC677FECA1AED65462EC8D5E4C5

[[ $# -le 1 && ${1:-} != -* ]] || { sed -n '2,13s/^# \{0,1\}//p' "$0"; exit 1; }
RELEASE=${1:-}
if [[ -n $RELEASE ]]; then
  # cdimage.kali.org keeps the last releases as kali-<release>/
  [[ $RELEASE =~ ^[0-9]{4}\.[0-9]+$ ]] || die "RELEASE looks like 2026.2, not '$RELEASE'"
  BASE_URL=https://cdimage.kali.org/kali-$RELEASE
else
  BASE_URL=https://cdimage.kali.org/current
fi

for tool in curl gpg; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found (brew install gnupg for gpg)"
done
SEVENZIP=$(command -v 7zz || command -v 7z || true)
[[ -n $SEVENZIP ]] || die "7-Zip not found: brew install sevenzip (7zz), or p7zip (7z)"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
# HTTPS only, redirects included: cdimage.kali.org redirects to a mirror.
CURL=(curl -fL --proto '=https' --proto-redir '=https' --retry 3)

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$REPO_ROOT/artifacts/kali
mkdir -p "$OUT"
WORK=$(mktemp -d)
export GNUPGHOME=$WORK/gnupg
trap 'gpgconf --kill all >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

# --- 1. The signed checksum list -------------------------------------------------
log "Checking $BASE_URL/SHA256SUMS against Kali's key $KALI_KEY_FPR"
"${CURL[@]}" -sS -o "$WORK/SHA256SUMS" "$BASE_URL/SHA256SUMS"
"${CURL[@]}" -sS -o "$WORK/SHA256SUMS.gpg" "$BASE_URL/SHA256SUMS.gpg"
"${CURL[@]}" -sS -o "$WORK/archive-key.asc" "$KALI_KEY_URL"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --import "$WORK/archive-key.asc" 2>/dev/null \
  || die "could not import the key from $KALI_KEY_URL"
# Trust nothing but a good signature by the pinned key: VALIDSIG's last field is
# the fingerprint of the signing key's primary key (GnuPG doc/DETAILS).
STATUS=$(gpg --batch --status-fd 1 --verify "$WORK/SHA256SUMS.gpg" "$WORK/SHA256SUMS" 2>/dev/null || true)
printf '%s\n' "$STATUS" | awk -v fpr="$KALI_KEY_FPR" '$2 == "VALIDSIG" && $NF == fpr { ok = 1 } END { exit !ok }' \
  || die "SHA256SUMS is not signed by Kali's key $KALI_KEY_FPR: refusing it"

# --- 2. The image -------------------------------------------------------------------
LINE=$(grep -E '^[0-9a-f]{64}  kali-linux-[0-9.]+-qemu-amd64\.7z$' "$WORK/SHA256SUMS" || true)
[[ -n $LINE && $(printf '%s\n' "$LINE" | wc -l) -eq 1 ]] \
  || die "SHA256SUMS lists no single kali-linux-*-qemu-amd64.7z"
WANT=${LINE%% *}
ARCHIVE=${LINE##* }
VERSION=${ARCHIVE#kali-linux-}; VERSION=${VERSION%-qemu-amd64.7z}
ARCHIVE_PATH=$OUT/$ARCHIVE

if [[ -f $ARCHIVE_PATH && $(sha256 "$ARCHIVE_PATH") == "$WANT" ]]; then
  log "$ARCHIVE is already here and verified"
else
  log "Downloading $ARCHIVE (several GB; an interrupted download resumes on the next run)"
  # A complete but corrupt file makes the resume fail (nothing left to fetch): start over.
  "${CURL[@]}" -C - -o "$ARCHIVE_PATH" "$BASE_URL/$ARCHIVE" \
    || { log "Resume failed; downloading from the start"; rm -f "$ARCHIVE_PATH"
         "${CURL[@]}" -o "$ARCHIVE_PATH" "$BASE_URL/$ARCHIVE"; }
  log "Checking its SHA-256"
  [[ $(sha256 "$ARCHIVE_PATH") == "$WANT" ]] \
    || { rm -f "$ARCHIVE_PATH"; die "SHA-256 mismatch for $ARCHIVE: deleted it, run again"; }
fi

# --- 3. Extract the disk --------------------------------------------------------------
# Exactly one .qcow2 with a plain name; nothing else in the archive is extracted.
LISTING=$("$SEVENZIP" l -slt "$ARCHIVE_PATH") || die "7-Zip could not read $ARCHIVE"
QCOW=$(printf '%s\n' "$LISTING" | sed -n 's/^Path = //p' | grep -E '\.qcow2$' || true)
[[ -n $QCOW && $(printf '%s\n' "$QCOW" | wc -l) -eq 1 ]] || die "expected one .qcow2 inside $ARCHIVE"
[[ $QCOW =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.qcow2$ ]] || die "unexpected name inside $ARCHIVE: '$QCOW'"
QCOW_BYTES=$(printf '%s\n' "$LISTING" | awk -v q="$QCOW" '/^Path = /{ p = substr($0, 8) } /^Size = / && p == q { print substr($0, 8); exit }')

DIR_REL=artifacts/kali/${ARCHIVE%.7z}
QCOW_PATH=$REPO_ROOT/$DIR_REL/$QCOW
if [[ -f $QCOW_PATH && -n $QCOW_BYTES && $(wc -c <"$QCOW_PATH") -eq $QCOW_BYTES ]]; then
  log "$DIR_REL/$QCOW is already extracted"
else
  rm -rf "${REPO_ROOT:?}/$DIR_REL"
  mkdir -p "$REPO_ROOT/$DIR_REL"
  log "Extracting $QCOW into $DIR_REL/"
  "$SEVENZIP" e -y -bd -o"$REPO_ROOT/$DIR_REL" "$ARCHIVE_PATH" "$QCOW" >/dev/null \
    || die "7-Zip could not extract $QCOW (it checks each file's CRC)"
fi

# --- 4. Its virtual size ----------------------------------------------------------------
# qcow2 header (QEMU docs/interop/qcow2.txt): bytes 0-3 are "QFI\xfb", bytes
# 24-31 the virtual disk size; all numbers big-endian.
[[ $(od -An -tx1 -N4 "$QCOW_PATH" | tr -d ' \n') == 514649fb ]] || die "$QCOW is not a qcow2 image"
VSIZE=0
for byte in $(od -An -tu1 -j24 -N8 "$QCOW_PATH"); do VSIZE=$(( VSIZE * 256 + byte )); done
(( VSIZE > 0 )) || die "could not read the virtual size of $QCOW"
GIB=$(( (VSIZE + 1073741823) / 1073741824 ))

# --- 5. Report ---------------------------------------------------------------------------
log "Kali $VERSION: $DIR_REL/$QCOW, virtual size $VSIZE bytes (size_gb $GIB)"
cat <<EOF

# Add under labs.cyber.vms in config/lab.yml; vmid is any free one in 3000-3999:
      - vmid: 3001
        name: kali
        node: pve2              # pve1 already runs labgw and obs
        memory: 2048            # Kali's QEMU guide uses 2 GB and 2 cores
        cores: 2
        os: l26
        firmware: bios          # MBR with grub-pc (kali-vm README)
        bus: virtio
        nic: virtio
        agent: true             # QEMU guest agent pre-installed (kali-vm README)
        vnet: cyber
        disks:
          - image: $DIR_REL/$QCOW
            size_gb: $GIB
EOF
log "Kali's documented default login is kali / kali: change the password first."
