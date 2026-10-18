#!/usr/bin/env bash
# Exercise daemon upgrades without installing a package or starting a service.
set -euo pipefail
cd "$(dirname "$0")/.."
pass=0
run_daemon() {
  local fake rc=0
  fake=$(mktemp -d)
  mkdir -p "$fake/bin" "$fake/tmp"
  touch "$fake/bin/docker-lxc-daemon"
  chmod +x "$fake/bin/docker-lxc-daemon"
  cat > "$fake/run.sh" <<'HARNESS'
set -euo pipefail
msg_info() { echo "$*"; }
msg_ok() { echo "$*"; }
die() { echo "ERROR $*"; exit 1; }
DAEMON_REPO=games-on-whales/LXC2Docker
DAEMON_MIN_VERSION=0.1.3
STORAGE=stores
BRIDGE_SPEC=vmbr0=192.168.1/24:192.168.1.1
dpkg-query() { [ -z "${INSTALLED:-}" ] || echo "install ok installed $INSTALLED"; }
dpkg() {
  # The test cases need only compare versions 0.1.2, 0.1.3 and 0.1.4.
  [[ "$2" = 0.1.3 || "$2" = 0.1.4 ]]
}
dpkg-deb() { echo "${AVAILABLE:-0.1.3}"; }
curl() {
  case "$*" in
    *releases/latest*)
      [ "${NO_ASSET:-0}" = 0 ] || return 0
      echo '{"browser_download_url": "https://example.invalid/docker-lxc-daemon_0.1.3_amd64.deb"}' ;;
    *) echo DOWNLOAD; [ "${DOWNLOAD_FAIL:-0}" = 0 ] || return 7 ;;
  esac
}
apt-get() { echo APT-INSTALL; [ "${APT_FAIL:-0}" = 0 ]; }
systemctl() { echo "SYSTEMCTL $*"; }
HARNESS
  sed -n '/^# ---------- 1\. /,/^# ---------- 2\. /p' install.sh |
    sed -e "s#/usr/bin/docker-lxc-daemon#$fake/bin/docker-lxc-daemon#g" \
        -e "s#/etc/systemd/system#$fake/systemd#g" >> "$fake/run.sh"
  env TMPDIR="$fake/tmp" "$@" bash "$fake/run.sh" > "$fake/out" 2>&1 || rc=$?
  cat "$fake/out"
  echo "EXIT=$rc"
  if [ -z "$(ls -A "$fake/tmp")" ]; then echo CLEAN; else echo LEAK; fi
  rm -rf "$fake"
}
expect() {
  if [[ "$2" = *"$1"* ]]; then pass=$((pass + 1)); else
    printf 'FAIL: expected %s\n%s\n' "$1" "$2"; exit 1
  fi
}
reject() {
  if [[ "$2" = *"$1"* ]]; then printf 'FAIL: unexpected %s\n%s\n' "$1" "$2"; exit 1; fi
  pass=$((pass + 1))
}
for version in '' 0.1.2; do
  out=$(run_daemon INSTALLED="$version")
  expect APT-INSTALL "$out"
  expect 'SYSTEMCTL restart docker-lxc-daemon' "$out"
  expect EXIT=0 "$out"
  expect CLEAN "$out"
done
for version in 0.1.3 0.1.4; do
  out=$(run_daemon INSTALLED="$version")
  reject APT-INSTALL "$out"
  expect 'SYSTEMCTL restart docker-lxc-daemon' "$out"
  expect EXIT=0 "$out"
done
out=$(run_daemon AVAILABLE=0.1.2)
expect 'lacks the required CT-id fixes' "$out"
reject APT-INSTALL "$out"
reject SYSTEMCTL "$out"
expect EXIT=1 "$out"
expect CLEAN "$out"
out=$(run_daemon NO_ASSET=1)
expect 'No .deb found' "$out"
reject APT-INSTALL "$out"
reject SYSTEMCTL "$out"
for failure in DOWNLOAD_FAIL=1 APT_FAIL=1; do
  out=$(run_daemon "$failure")
  reject SYSTEMCTL "$out"
  expect CLEAN "$out"
  reject EXIT=0 "$out"
done
echo "$pass daemon checks passed"
