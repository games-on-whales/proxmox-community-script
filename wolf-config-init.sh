#!/usr/bin/env bash
# Seeds and pins Wolf's config.toml for this recipe, inside the upstream Wolf
# image. docker-compose.yml mounts it as /etc/cont-init.d/40-wolf-proxmox.sh, and
# the image's /entrypoint.sh *sources* every cont-init script as root before it
# hands over to the upstream /opt/gow/startup-app.sh (PulseAudio + Wolf under
# supervisord). Sourced, not run: no exit, and `return 1` aborts the start.
#
# - First start: write config.toml from the bundled default profile set, with a
#   fresh uuid. Without it Wolf generates its own default, which does not carry
#   this recipe's app list.
# - Every start: pin the GOW app images to WOLF_IMAGE_TAG, so changing it in
#   .env takes effect on the next restart.

wolf_cfg_file="${HOST_APPS_STATE_FOLDER:-/etc/wolf}/cfg/config.toml"
wolf_default_cfg=/opt/wolf-proxmox/default-config.toml

if [[ ! "${WOLF_IMAGE_TAG:=edge}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid WOLF_IMAGE_TAG: ${WOLF_IMAGE_TAG}" >&2
  return 1
fi

mkdir -p "$(dirname "$wolf_cfg_file")"
if [[ ! -f "$wolf_cfg_file" ]]; then
  gow_log "Seeding ${wolf_cfg_file} from ${wolf_default_cfg}"
  {
    echo "# A unique identifier for this host"
    echo "uuid = \"$(cat /proc/sys/kernel/random/uuid)\""
    cat "$wolf_default_cfg"
  } >"$wolf_cfg_file"
fi

gow_log "Pinning GOW app images to :${WOLF_IMAGE_TAG}"
sed -i -E \
  "s#(image[[:space:]]*=[[:space:]]*['\"]ghcr\\.io/games-on-whales/(firefox|retroarch|steam|pegasus|lutris|prismlauncher|xfce|es-de|kodi):)[^'\"]+(['\"])#\\1${WOLF_IMAGE_TAG}\\3#g" \
  "$wolf_cfg_file"

unset wolf_cfg_file wolf_default_cfg
