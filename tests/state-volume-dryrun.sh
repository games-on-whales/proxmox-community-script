#!/usr/bin/env bash
#
# Exercises install.sh's "Wolf state volume" section against a faked Proxmox
# storage layer, so allocation, reuse, formatting and migration can be verified
# without a PVE node. Run from the repo root:
#
#   bash tests/state-volume-dryrun.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n       expected: %s\n' "$1" "$2"; fail=$((fail+1)); }

# Runs section 2b with a stubbed pvesm/mkfs/mount and a scratch /etc/wolf.
#   $1 = storage type,  rest = env assignments
run_state() {
  local stype="$1"; shift
  local script; script=$(mktemp)
  cat > "$script" <<'HARNESS'
set -euo pipefail
YW=''; GN=''; RD=''; BL=''; CL=''
msg_info() { echo " > $*"; }
msg_ok()   { echo " ok $*"; }
msg_err()  { echo " ERR $*" >&2; }
die()      { msg_err "$*"; exit 1; }

FAKE=$(mktemp -d)
ETC_WOLF="$FAKE/etc-wolf"; mkdir -p "$ETC_WOLF"
[ -n "${SEED_STATE:-}" ] && echo "old-config" > "$ETC_WOLF/config.toml"

# The "volume" is a plain file standing in for the block device / raw image.
VOL="$FAKE/volume.img"
: > "$VOL"
[ "${VOL_EXISTS:-0}" = 1 ] || rm -f "$VOL"

pvesm() {
  case "$1" in
    list)  [ "${VOL_EXISTS:-0}" = 1 ] && echo "${STORAGE}:vm-0-wolf-state raw 214748364800 0"; return 0 ;;
    alloc) : > "$VOL"; echo "successfully created '${STORAGE}:${4%G}'"; return 0 ;;
    path)  [ -e "$VOL" ] || return 1; echo "$VOL"; return 0 ;;
  esac
}
# A blank volume has no filesystem; FS_PRESENT marks one that already does.
blkid() { [ "${FS_PRESENT:-0}" = 1 ] || return 2; case "$*" in *UUID*) echo "TEST-UUID-1234" ;; esac; return 0; }
mkfs.ext4() { FS_PRESENT=1; echo "MKFS-RAN"; }
mountpoint() { [ "${ALREADY_MOUNTED:-0}" = 1 ]; }
# Record mounts; copy through so migration can be observed.
mount() { echo "MOUNT $*"; MOUNTED_AT="${!#}"; mkdir -p "$MOUNTED_AT"; }
# A real umount leaves the mount point empty again — model that, so the caller's
# cleanup is exercised the way it behaves on a host.
umount() { echo "UMOUNT $*"; rm -rf "${1:?}"/* "${1:?}"/.[!.]* 2>/dev/null || true; }
STORAGE="${STORAGE:-teststore}"
STATE_GB="${STATE_GB:-200}"
STORAGE_TYPE="${STORAGE_TYPE:-lvmthin}"

# Section 2b only, with /etc/wolf and /etc/fstab redirected into the scratch dir.
sed -n '/---------- 2b\. the Wolf state volume/,/^# ---------- 3\./p' install.sh |
  sed -e '/^# ---------- 3\./d' \
      -e "s#/etc/wolf#$ETC_WOLF#g" \
      -e "s#/etc/fstab#$FAKE/fstab#g" > "$FAKE/section.sh"
# shellcheck disable=SC1090
source "$FAKE/section.sh"
echo "FSTAB: $(cat "$FAKE/fstab" 2>/dev/null || echo none)"
echo "RESULT volume=$STATE_VOLUME"
rm -rf "$FAKE"
HARNESS
  local out
  out=$(env STORAGE_TYPE="$stype" "$@" bash "$script" 2>&1 </dev/null || true)
  rm -f "$script"
  echo "$out"
}

expect() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "$2" ;; esac; }
reject() { case "$3" in *"$2"*) bad "$1" "must NOT contain: $2" ;; *) ok "$1" ;; esac; }

echo "install.sh Wolf state volume:"

# A fresh install allocates, formats, and mounts.
out=$(run_state lvmthin)
expect "allocates on a blank storage"      "Allocating a 200 GB Wolf state volume" "$out"
expect "formats the blank volume"          "MKFS-RAN"                              "$out"
expect "mounts it at /etc/wolf"            "MOUNT"                                 "$out"
expect "records it in fstab by UUID"       "UUID=TEST-UUID-1234"                   "$out"

# Block vs file storages get the naming pvesm expects.
out=$(run_state dir)
expect "file storages get a .raw name"     "wolf-state.raw"                        "$out"
out=$(run_state lvmthin)
reject "block storages get a bare name"    ".raw"                                  "$out"

# A re-run must reuse the volume and must never reformat it.
out=$(run_state lvmthin VOL_EXISTS=1 FS_PRESENT=1)
expect "reuses an existing volume"         "Reusing the existing Wolf state volume" "$out"
reject "never reformats existing game data" "MKFS-RAN"                             "$out"

# An already-mounted /etc/wolf is left completely alone.
out=$(run_state lvmthin ALREADY_MOUNTED=1)
expect "idempotent when already mounted"   "already mounted at"                    "$out"
reject "no allocation when already mounted" "Allocating"                           "$out"

# State left on the OS root by an older install is carried onto the volume.
out=$(run_state lvmthin SEED_STATE=1)
expect "migrates existing /etc/wolf"       "Migrated the existing"                 "$out"

echo
echo "  ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
