#!/usr/bin/env bash
# An unattended install must pass normalized units to Compose even when the
# caller exported bare installer values. No Proxmox host or Docker required.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=$(mktemp -d)
trap 'rm -rf "$DEST"' EXIT
cp .env.example "$DEST/.env"
# shellcheck source=/dev/null
source <(sed -n '/^set_env()/,/^}/p' install.sh)
export WOLF_MEMORY=16384 WOLF_DISK_SIZE=100
set_env WOLF_MEMORY 16384M
set_env WOLF_DISK_SIZE 100G
set_env WOLF_STATE_SIZE 400G
# A child process sees these before it considers .env, as Compose does.
bash -c '[[ $WOLF_MEMORY == 16384M && $WOLF_DISK_SIZE == 100G && $WOLF_STATE_SIZE == 400G ]]'
grep -qx WOLF_MEMORY=16384M "$DEST/.env"
grep -qx WOLF_DISK_SIZE=100G "$DEST/.env"
grep -qx WOLF_STATE_SIZE=400G "$DEST/.env"
echo 'PASS: exported presets and .env agree, including memory/disk units'

# Earlier installs pinned the recipe's own wolf-proxmox image in .env; a re-run
# must drop that so the upstream channel image is used, and keep any other pin.
for pin in ghcr.io/games-on-whales/wolf-proxmox:latest ghcr.io/games-on-whales/wolf-proxmox@sha256:abc; do
  printf 'WOLF_IMAGE=%s\nWOLF_LAN_IP=192.168.1.50/24\n' "$pin" > "$DEST/.env"
  eval "$(grep -F 'wolf-proxmox[:@]' install.sh)"
  ! grep -q '^WOLF_IMAGE=' "$DEST/.env"
  grep -qx WOLF_LAN_IP=192.168.1.50/24 "$DEST/.env"
done
printf 'WOLF_IMAGE=ghcr.io/games-on-whales/wolf:beta\n' > "$DEST/.env"
eval "$(grep -F 'wolf-proxmox[:@]' install.sh)"
grep -qx WOLF_IMAGE=ghcr.io/games-on-whales/wolf:beta "$DEST/.env"
echo 'PASS: the old wolf-proxmox image pin is dropped, other pins are kept'
