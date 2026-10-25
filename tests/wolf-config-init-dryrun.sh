#!/usr/bin/env bash
#
# Exercises wolf-config-init.sh the way the upstream Wolf image runs it: sourced
# by /entrypoint.sh under `set -e`, with gow_log defined. No container needed.
# Run from the repo root:
#
#   bash tests/wolf-config-init-dryrun.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n       expected: %s\n' "$1" "$2"; fail=$((fail+1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The script reads the default profile set from its in-container mount point.
sed "s#/opt/wolf-proxmox/default-config.toml#$PWD/config/default-config.toml#" \
  wolf-config-init.sh > "$work/init.sh"

run_init() { # run_init <state dir> [env...] — source like /entrypoint.sh does
  local state="$1"; shift
  env HOST_APPS_STATE_FOLDER="$state" "$@" bash -c '
    set -e
    gow_log() { echo "$*"; }
    source "$1"
    echo "ENTRYPOINT CONTINUED"
  ' _ "$work/init.sh" 2>&1
}

expect() { # expect <name> <needle> <haystack>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "$2" ;; esac
}

echo "wolf-config-init.sh:"

state="$work/state"
out=$(run_init "$state" WOLF_IMAGE_TAG=fedora)
cfg="$state/cfg/config.toml"
expect "hands back to the entrypoint" "ENTRYPOINT CONTINUED" "$out"
if [ -f "$cfg" ]; then ok "seeds cfg/config.toml on first start"; else bad "seeds cfg/config.toml on first start" "$cfg"; fi
expect "the seeded config has a uuid" 'uuid = "' "$(head -2 "$cfg")"
expect "the seeded config has the profile set" "ghcr.io/games-on-whales/steam:" "$(cat "$cfg")"
expect "app images are pinned to the tag" 'image = "ghcr.io/games-on-whales/steam:fedora"' "$(cat "$cfg")"
case "$(cat "$cfg")" in
  *"steam:edge"*) bad "no app image keeps the old tag" "no steam:edge" ;;
  *) ok "no app image keeps the old tag" ;;
esac
expect "images it does not manage are left alone" "wolf-ui:main" "$(cat "$cfg")"

# A second start keeps the config (uuid, pairings) and only re-pins the tags.
uuid=$(grep -m1 '^uuid' "$cfg")
echo 'paired_marker = true' >> "$cfg"
out=$(run_init "$state" WOLF_IMAGE_TAG=edge)
expect "a restart keeps the uuid" "$uuid" "$(cat "$cfg")"
expect "a restart keeps local edits" "paired_marker = true" "$(cat "$cfg")"
expect "a restart re-pins to the new tag" 'image = "ghcr.io/games-on-whales/steam:edge"' "$(cat "$cfg")"

# No tag means edge, matching the compose default.
out=$(run_init "$work/fresh")
expect "the tag defaults to edge" 'steam:edge' "$(cat "$work/fresh/cfg/config.toml")"

# An unusable tag must stop the start, not write it into config.toml.
out=$(run_init "$work/bad" 'WOLF_IMAGE_TAG=x;rm -rf /' || true)
expect "an invalid tag is reported" "Invalid WOLF_IMAGE_TAG" "$out"
case "$out" in
  *"ENTRYPOINT CONTINUED"*) bad "an invalid tag aborts the start" "no ENTRYPOINT CONTINUED" ;;
  *) ok "an invalid tag aborts the start" ;;
esac

# Sourced into the entrypoint's shell, so it must not leak its own variables.
leak=$(env HOST_APPS_STATE_FOLDER="$work/leak" bash -c '
  set -e; gow_log() { :; }; source "$1"; echo "${wolf_cfg_file-unset} ${wolf_default_cfg-unset}"' _ "$work/init.sh")
expect "leaves no variables behind" "unset unset" "$leak"

echo
echo "  ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
