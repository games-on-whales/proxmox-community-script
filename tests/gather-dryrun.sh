#!/usr/bin/env bash
#
# Exercises install.sh's "gather settings" section (storage / disk / CPU / RAM /
# GPU selection) against a faked Proxmox host, so the prompts and their bounds
# can be verified without a PVE node. Run from the repo root:
#
#   bash tests/gather-dryrun.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n       expected: %s\n' "$1" "$2"; fail=$((fail+1)); }

# Runs the gather section with fake host data.
#   $1 = "tty" | "notty",  $2 = keystrokes,  rest = env assignments
run_gather() {
  local mode="$1" keys="$2"; shift 2
  local script; script=$(mktemp)
  cat > "$script" <<'HARNESS'
set -euo pipefail
YW=''; GN=''; RD=''; BL=''; CL=''
msg_info() { echo " > $*"; }
msg_ok()   { echo " ok $*"; }
msg_err()  { echo " ERR $*" >&2; }
die()      { msg_err "$*"; exit 1; }
# Two rootdir storages: "local-lvm" nearly full (~9 GB), "stores" roomy (~6.6 TB).
pvesm() {
  printf 'Name Type Status Total Used Available %%\n'
  printf 'local-lvm lvmthin active 100000000 90000000 10000000 90.00\n'
  printf 'stores zfspool active 8000000000 1000000000 7000000000 12.50\n'
}
nproc()    { echo 16; }
lspci()    { echo '00:02.0 "VGA compatible controller" "NVIDIA" "GeForce RTX 5080"'; }
ip()       { echo "default via 192.168.1.1 dev vmbr0"; }
modinfo()  { return 1; }   # no nvidia module here, so the probe is skipped

FAKE=$(mktemp -d)
mkdir -p "$FAKE/renderD128/device/drivers/nvidia"
ln -s drivers/nvidia "$FAKE/renderD128/device/driver"
if [ "${TWO_GPUS:-1}" = 1 ]; then
  mkdir -p "$FAKE/renderD129/device/drivers/amdgpu"
  ln -s drivers/amdgpu "$FAKE/renderD129/device/driver"
fi
echo "MemTotal:       65536000 kB" > "$FAKE/meminfo"   # 64000 MB host

# Helpers + section 0 only — drop the banner and the root/pveversion preflight.
sed -n '/---------- prompt helpers/,$p' install.sh |
  sed -e "/^cat <<'BANNER'/,/^command -v curl/d" \
      -e '/^# ---------- 1\. /,$d' \
      -e 's#/sys/class/drm/renderD\*#'"$FAKE"'/renderD*#' \
      -e 's#/proc/meminfo#'"$FAKE"'/meminfo#' > "$FAKE/section.sh"
# shellcheck disable=SC1090
source "$FAKE/section.sh"
echo "RESULT storage=$STORAGE disk=$CT_DISK cpu=$CT_CPU ram=$CT_RAM gpu=$RENDER_NODE vendor=$RENDER_VENDOR"
rm -rf "$FAKE"
HARNESS
  local out
  if [ "$mode" = tty ]; then
    out=$(printf '%b' "$keys" | env "$@" script -qec "bash $script" /dev/null 2>&1 | tr -d '\r' || true)
  else
    out=$(env "$@" bash "$script" 2>&1 </dev/null || true)
  fi
  rm -f "$script"
  echo "$out"
}

expect() { # expect <name> <needle> <output>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "$2" ;; esac
}

echo "install.sh gather section:"

# Presets are taken verbatim and nothing is asked.
out=$(run_gather notty '' DLD_STORAGE=stores WOLF_DISK_SIZE=500G WOLF_CPUS=8 \
  WOLF_MEMORY=32768M WOLF_RENDER_NODE=/dev/dri/renderD129 WOLF_LAN_IP=192.168.1.50/24)
expect "presets are used as-is" \
  "RESULT storage=stores disk=500 cpu=8 ram=32768 gpu=/dev/dri/renderD129 vendor=AMD" "$out"

# Candidates are listed the way the Wolf quickstart lists them, and with no
# terminal every question takes option 1 / its default.
out=$(run_gather notty '' WOLF_LAN_IP=192.168.1.50/24)
expect "storages are listed as 'name (type, N GB free)'" "1) local-lvm (lvmthin, 9 GB free)" "$out"
expect "GPUs are listed as 'vendor name (driver, node)'" \
  "1) NVIDIA GeForce RTX 5080 (nvidia, /dev/dri/renderD128)" "$out"
expect "defaults without a terminal" \
  "RESULT storage=local-lvm disk=9 cpu=4 ram=4096 gpu=/dev/dri/renderD128 vendor=NVIDIA" "$out"

# Presets that cannot work abort rather than silently installing something else.
out=$(run_gather notty '' DLD_STORAGE=local-lvm WOLF_DISK_SIZE=500G WOLF_LAN_IP=192.168.1.50/24)
expect "disk larger than free space is rejected" "does not fit the 9 GB free on local-lvm" "$out"

out=$(run_gather notty '' WOLF_MEMORY=999999M WOLF_LAN_IP=192.168.1.50/24)
expect "RAM larger than the host is rejected" "not between 1 and the host's 64000 MB" "$out"

out=$(run_gather notty '' WOLF_CPUS=99 WOLF_LAN_IP=192.168.1.50/24)
expect "core count above the host is rejected" "not between 1 and the host's 16 cores" "$out"

out=$(run_gather notty '' WOLF_RENDER_NODE=/dev/dri/renderD200 WOLF_LAN_IP=192.168.1.50/24)
expect "unknown render node is rejected" "Render node /dev/dri/renderD200 not found" "$out"

out=$(run_gather notty '' DLD_STORAGE=nope WOLF_LAN_IP=192.168.1.50/24)
expect "unknown storage is rejected" "Storage nope not found" "$out"

# Interactive: answers are taken, and a bad answer re-asks instead of aborting.
out=$(run_gather tty '2\n200\n4\n16384\n2\n192.168.1.77/24\n')
expect "interactive answers are used" \
  "RESULT storage=stores disk=200 cpu=4 ram=16384 gpu=/dev/dri/renderD129 vendor=AMD" "$out"

out=$(run_gather tty '9\n2\n999999\n50\n99\n4\n999999\n8192\n9\n1\n192.168.1.77/24\n')
expect "out-of-range answers re-ask" "Invalid selection. Enter a number between 1 and 2." "$out"
expect "out-of-range values re-ask" \
  "RESULT storage=stores disk=50 cpu=4 ram=8192 gpu=/dev/dri/renderD128 vendor=NVIDIA" "$out"

# A single GPU needs no question — it is reported and used.
out=$(run_gather notty '' TWO_GPUS=0 WOLF_LAN_IP=192.168.1.50/24)
expect "single GPU is auto-selected" "Detected GPU: NVIDIA GeForce RTX 5080" "$out"

echo
echo "  ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
