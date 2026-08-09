#!/usr/bin/env bash
#
# Exercises uninstall.sh against a faked Proxmox host, so the removal order and
# — more importantly — what it refuses to remove can be verified without a PVE
# node. Run from the repo root:
#
#   bash tests/uninstall-dryrun.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n       expected: %s\n' "$1" "$2"; fail=$((fail+1)); }

# Runs uninstall.sh with a stubbed host. Args are passed to the script; env
# assignments come through the caller's environment.
run_uninstall() {
  local fake; fake=$(mktemp -d)
  mkdir -p "$fake/etc" "$fake/dest"
  printf 'WOLF_LAN_IP=192.168.1.50/24\nWOLF_STATE_VOLUME=local-lvm:vm-9000-wolf-state\n' > "$fake/dest/.env"
  : > "$fake/dest/docker-compose.yml"
  printf 'UUID=root / ext4 defaults 0 1\nUUID=state /etc/wolf ext4 defaults,nofail 0 2\n' > "$fake/etc/fstab"

  # Some of these calls are silenced by the script itself, so every stub records
  # what it was asked to do in a log the assertions read back.
  : > "$fake/removed"; echo 0 > "$fake/rounds"
  { echo "LOG=$fake/calls.log"; echo "FAKE=$fake"
    cat <<'STUBS'
say()       { echo "$*" >> "$LOG"; }
id()        { echo 0; }
# A real docker forgets what it removed. RESURRECT_ROUNDS additionally models
# the restart watcher putting the base Wolf CT back after its record was
# deleted — `docker ps` lists it again — which is the race the sweep exists for.
docker()    { case "$1" in
                version) return 0 ;;
                compose) say "COMPOSE $*" ;;
                ps)      for n in wolf WolfSteam_1234 unrelated-app; do
                           if grep -qx "$n" "$FAKE/removed"; then
                             rounds=$(cat "$FAKE/rounds")
                             if [ "$n" = wolf ] && [ "$rounds" -lt "${RESURRECT_ROUNDS:-0}" ]; then
                               echo $((rounds + 1)) > "$FAKE/rounds"
                               grep -vx wolf "$FAKE/removed" > "$FAKE/removed.tmp" || true
                               mv "$FAKE/removed.tmp" "$FAKE/removed"
                             else
                               continue
                             fi
                           fi
                           echo "$n"
                         done ;;
                rm)      say "DOCKER-RM ${!#}"; echo "${!#}" >> "$FAKE/removed" ;;
              esac; return 0; }
# ORPHAN_CT models the end state the sweep cannot reach: a CT restarted after
# its Docker record was deleted, so Docker cannot see it at all.
pct()       { [ "${ORPHAN_CT:-0}" = 1 ] || return 0
              printf 'VMID       Status     Lock         Name\n'
              printf '100        running                 wolf\n'
              printf '101        running                 unrelated-ct\n'; }
systemctl() { say "SYSTEMCTL $*"; }
apt-get()   { say "APT $*"; }
dpkg()      { [ "${DAEMON_INSTALLED:-1}" = 1 ]; }
pvesm()     { say "PVESM $*"; }
mountpoint() { [ "${STATE_MOUNTED:-1}" = 1 ]; }
umount()    { say "UMOUNT $*"; }
udevadm()   { :; }
STUBS
    # /etc paths into the scratch dir; the mount point and fstab are the two
    # that matter, and redirecting the whole prefix keeps the rest harmless.
    sed -e "s#/etc/#$fake/etc/#g" uninstall.sh
  } > "$fake/run.sh"

  local out
  out=$(WOLF_DEST="$fake/dest" WOLF_RUNTIME_DIR="$fake/run-wolf" \
        bash "$fake/run.sh" "$@" 2>&1 </dev/null || true)
  echo "$out"
  cat "$fake/calls.log" 2>/dev/null || true
  echo "FSTAB-LEFT: $(tr '\n' '|' < "$fake/etc/fstab" 2>/dev/null || echo gone)"
  [ -d "$fake/dest" ] && echo "DEST-LEFT: yes"
  rm -rf "$fake"
}

expect() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "$2" ;; esac; }
reject() { case "$3" in *"$2"*) bad "$1" "must NOT contain: $2" ;; *) ok "$1" ;; esac; }

echo "uninstall.sh:"

out=$(run_uninstall --yes)

# The Wolf CT is restart:unless-stopped, so the daemon's watcher puts it back
# within five seconds of any stop it did not hear about. Removal has to go
# through Docker, which clears the record the watcher reads — stopping the CT
# with pct never sticks.
expect "takes the stack down through compose" "COMPOSE compose -f docker-compose.yml down" "$out"
expect "removes the Wolf container"           "DOCKER-RM wolf"                             "$out"
expect "removes the session CTs Wolf left"    "DOCKER-RM WolfSteam_1234"                   "$out"
reject "leaves unrelated containers alone"    "DOCKER-RM unrelated-app"                    "$out"

expect "stops and disables the daemon"        "SYSTEMCTL disable --now docker-lxc-daemon"  "$out"
expect "uninstalls the daemon package"        "APT purge -y docker-lxc-daemon"             "$out"
expect "unmounts the state volume"            "UMOUNT"                                     "$out"
expect "removes the recipe directory"         "removed"                                    "$out"
reject "removes the recipe directory (gone)"  "DEST-LEFT: yes"                             "$out"

# fstab is edited on the mount-point field, so nothing else in it can be caught.
expect "drops the /etc/wolf fstab line"       "FSTAB-LEFT: UUID=root / ext4 defaults 0 1|" "$out"

# Game data is the one thing nothing else holds a copy of. It is never removed
# unless that is what was asked for.
reject "never frees the state volume by default" "PVESM free"                              "$out"
expect "says where the game data still is"    "local-lvm:vm-9000-wolf-state"               "$out"

# The restart watcher can put a container back between the stop landing and the
# record being deleted. One removal is not enough; the sweep has to converge.
out=$(RESURRECT_ROUNDS=2 run_uninstall --yes)
expect "removes a container that came back"   "DOCKER-RM wolf"                            "$out"
expect "sweeps until nothing is left"         "Wolf containers removed"                   "$out"
case $(grep -c '^DOCKER-RM wolf$' <<<"$out") in
  1) bad "sweeps until nothing is left (once)" "wolf removed more than once" ;;
  *) ok  "removes it again each time it returns" ;;
esac

# A daemon that never lets go is named, not silently left behind.
out=$(RESURRECT_ROUNDS=99 run_uninstall --yes)
expect "gives up loudly, not silently"        "Still present after 3 removal rounds"      "$out"

# The end state the sweep cannot see: restarted after its record was deleted, so
# Docker has no idea it exists. Only visible once the daemon is stopped.
out=$(ORPHAN_CT=1 run_uninstall --yes)
expect "names the orphaned CT"                "Proxmox CTs left behind with no Docker record: 100 (wolf)" "$out"
reject "leaves unrelated CTs out of it"       "unrelated-ct"                              "$out"
expect "says how to remove it"                "pct stop <vmid> && pct destroy <vmid>"     "$out"

out=$(run_uninstall --yes)
reject "no orphan warning when there is none" "left behind with no Docker record"         "$out"

out=$(run_uninstall --yes --purge-state)
expect "--purge-state frees the volume" "PVESM free local-lvm:vm-9000-wolf-state"          "$out"

out=$(run_uninstall --yes --keep-daemon)
expect "--keep-daemon still stops it"   "SYSTEMCTL disable --now docker-lxc-daemon"        "$out"
reject "--keep-daemon keeps the package" "APT purge"                                       "$out"

# Without a terminal there is nobody to confirm to, and this removes a machine's
# streaming host — so it stops rather than assuming consent.
out=$(run_uninstall)
expect "refuses to run unconfirmed"     "No terminal to confirm on"                        "$out"
reject "nothing is touched when it stops" "SYSTEMCTL"                                      "$out"

out=$(run_uninstall --nonsense)
expect "rejects unknown options"        "Unknown option --nonsense"                        "$out"

echo
echo "  ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
