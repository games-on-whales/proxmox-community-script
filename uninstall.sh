#!/usr/bin/env bash
#
# Wolf on Proxmox (LXC2Docker) — uninstaller.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/games-on-whales/proxmox-community-script/main/uninstall.sh)"
#
# Reverses install.sh: takes the Wolf CT and any session CTs down, removes
# docker-lxc-daemon and the host prerequisites, and unmounts /etc/wolf.
#
# The Wolf CT is declared restart:unless-stopped, so the daemon's restart
# watcher brings it straight back if it is stopped from outside Docker — `pct
# stop 100` looks like a crash to the watcher and is undone within five seconds.
# Removing it has to go through Docker, which clears the record the watcher
# reads. That is what this script does, and it is why stopping the CT by hand
# never sticks.
#
# The state volume — config, client pairings and the game library — is KEPT
# unless --purge-state is given, because nothing else holds a copy of it.
#
# Options:
#   --yes           don't ask for confirmation
#   --purge-state   also free the Wolf state volume (destroys the game library)
#   --keep-daemon   leave docker-lxc-daemon installed (still stopped/disabled)
#
set -euo pipefail

YW=$'\033[33m'; GN=$'\033[1;92m'; RD=$'\033[01;31m'; BL=$'\033[36m'; CL=$'\033[m'
msg_info() { echo -e " ${YW}▶${CL} $*"; }
msg_ok()   { echo -e " ${GN}✓${CL} $*"; }
msg_err()  { echo -e " ${RD}✗${CL} $*" >&2; }
die()      { msg_err "$*"; exit 1; }

ASSUME_YES=0; PURGE_STATE=0; KEEP_DAEMON=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y)     ASSUME_YES=1 ;;
    --purge-state) PURGE_STATE=1 ;;
    --keep-daemon) KEEP_DAEMON=1 ;;
    *) die "Unknown option ${arg}. Usage: uninstall.sh [--yes] [--purge-state] [--keep-daemon]" ;;
  esac
done

DEST="${WOLF_DEST:-/opt/wolf-proxmox}"

[ "$(id -u)" -eq 0 ] || die "Run as root on the Proxmox VE host."

# The recipe's .env records what the installer chose, including the state volume
# it allocated. Read only the keys we need rather than sourcing a file of
# arbitrary shell.
env_get() {
  [ -f "${DEST}/.env" ] || return 0
  sed -n "s/^$1=//p" "${DEST}/.env" | tail -1
}
STATE_VOLUME="${WOLF_STATE_VOLUME:-$(env_get WOLF_STATE_VOLUME)}"

echo
echo -e " ${BL}Removing Wolf on Proxmox.${CL} This will:"
echo "   • stop and remove the Wolf CT and any session CTs it left behind"
if [ "$KEEP_DAEMON" = 1 ]; then
  echo "   • stop and disable docker-lxc-daemon (the package stays installed)"
else
  echo "   • stop docker-lxc-daemon and uninstall the package"
fi
echo "   • remove the uinput/udev/tmpfiles prerequisites and ${DEST}"
echo "   • unmount /etc/wolf and drop its fstab entry"
if [ "$PURGE_STATE" = 1 ]; then
  echo -e "   ${RD}• DESTROY the state volume ${STATE_VOLUME:-(none found)} — config, pairings and the game library${CL}"
else
  echo "   • keep the state volume ${STATE_VOLUME:-(none recorded)} — free it with 'pvesm free <volid>' when you are sure"
fi
echo
if [ "$ASSUME_YES" = 0 ]; then
  [ -t 0 ] || die "No terminal to confirm on — re-run with --yes."
  read -rp " Type 'yes' to continue: " reply
  [ "$reply" = "yes" ] || die "Aborted — nothing was changed."
fi

# ---------- 1. the Wolf CT and its sessions ----------
# Through Docker, so the daemon forgets the container instead of restarting it.
if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
  if [ -f "${DEST}/docker-compose.yml" ]; then
    msg_info "Taking the Wolf stack down"
    compose_args=(-f docker-compose.yml)
    if [ -f "${DEST}/docker-compose.nvidia.yml" ]; then
      compose_args+=(-f docker-compose.nvidia.yml)
    fi
    (cd "$DEST" && docker compose "${compose_args[@]}" down --remove-orphans --timeout 60) ||
      msg_err "compose down failed — falling back to removing the container directly"
  fi
  # Whatever compose could not account for: the Wolf CT itself, and the session
  # CTs Wolf launches (named after the app that started them, WolfSteam_...).
  # They are Wolf's children, so they go with it.
  leftovers=$(docker ps -a --format '{{.Names}}' 2>/dev/null |
    grep -E '^(wolf$|Wolf|Prismlauncher)' || true)
  for name in $leftovers; do
    msg_info "Removing container ${name}"
    docker rm -f "$name" >/dev/null 2>&1 || msg_err "Could not remove ${name}"
  done
  msg_ok "Wolf containers removed"
else
  msg_info "No working Docker socket — skipping container removal"
fi

# ---------- 2. docker-lxc-daemon ----------
msg_info "Stopping docker-lxc-daemon"
systemctl disable --now docker-lxc-daemon >/dev/null 2>&1 || true
rm -rf /etc/systemd/system/docker-lxc-daemon.service.d
if [ "$KEEP_DAEMON" = 0 ] && dpkg -s docker-lxc-daemon >/dev/null 2>&1; then
  apt-get purge -y docker-lxc-daemon
fi
systemctl daemon-reload
msg_ok "docker-lxc-daemon removed"

# ---------- 3. the state mount ----------
if mountpoint -q /etc/wolf; then
  msg_info "Unmounting /etc/wolf"
  umount /etc/wolf || msg_err "Could not unmount /etc/wolf — something still has it open."
fi
if grep -q ' /etc/wolf ' /etc/fstab 2>/dev/null; then
  # Match on the mount point field, so nothing else in fstab can be caught by it.
  awk '$2 != "/etc/wolf"' /etc/fstab > /etc/fstab.wolf-uninstall && \
    mv /etc/fstab.wolf-uninstall /etc/fstab
  msg_ok "fstab entry for /etc/wolf removed"
fi

if [ "$PURGE_STATE" = 1 ]; then
  [ -n "$STATE_VOLUME" ] || die "No state volume recorded in ${DEST}/.env — free it by hand with 'pvesm free <volid>'."
  msg_info "Freeing the state volume ${STATE_VOLUME}"
  pvesm free "$STATE_VOLUME" || die "Could not free ${STATE_VOLUME}."
  rmdir /etc/wolf 2>/dev/null || true
  msg_ok "State volume ${STATE_VOLUME} destroyed"
else
  msg_ok "State volume ${STATE_VOLUME:-(none recorded)} kept — /etc/wolf is now just an empty mount point"
fi

# ---------- 4. host prerequisites + the recipe ----------
msg_info "Removing the host prerequisites"
rm -f /etc/udev/rules.d/85-wolf-virtual-inputs.rules
udevadm control --reload-rules >/dev/null 2>&1 || true
rm -f /etc/modules-load.d/uinput.conf /etc/tmpfiles.d/wolf-proxmox.conf
rm -rf "${WOLF_RUNTIME_DIR:-/run/wolf}" "$DEST"
msg_ok "Prerequisites and ${DEST} removed"

echo
echo -e " ${GN}Wolf on Proxmox removed.${CL}"
echo "   The uinput module stays loaded until the next reboot."
echo "   The Docker CLI (docker-ce-cli, docker-compose-plugin) was left installed."
if [ "$PURGE_STATE" = 0 ] && [ -n "$STATE_VOLUME" ]; then
  echo -e "   ${BL}Game data:${CL}    ${STATE_VOLUME} — 'pvesm free ${STATE_VOLUME}' destroys it."
fi
echo
