#!/usr/bin/env bash
# An unattended install must pass normalized units to Compose even when the
# caller exported bare installer values. No Proxmox host or Docker required.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=$(mktemp -d)
trap 'rm -rf "$DEST"' EXIT
cp .env.example "$DEST/.env"
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
