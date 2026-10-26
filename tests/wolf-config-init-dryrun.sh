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

# Keyboard, locale and timezone reach every docker app's env.
state="$work/kb"
run_init "$state" WOLF_KEYBOARD=de WOLF_KEYBOARD_VARIANT=nodeadkeys WOLF_LOCALE=de_DE.UTF-8 \
  WOLF_TZ=Europe/Berlin >/dev/null
cfg="$state/cfg/config.toml"
docker_apps=$(grep -cE "^type = ['\"]docker['\"]" "$cfg")
for v in XKB_DEFAULT_LAYOUT=de XKB_DEFAULT_VARIANT=nodeadkeys LANG=de_DE.UTF-8 \
         LANGUAGE=de_DE:de TZ=Europe/Berlin; do
  n=$(grep -o "\"$v\"" "$cfg" | wc -l)
  if [ "$n" -eq "$docker_apps" ]; then ok "$v is set for all $docker_apps docker apps"
  else bad "$v is set for all $docker_apps docker apps" "$docker_apps, got $n"; fi
done
expect "multi-line env arrays stay multi-line" "    'LOGLEVEL=INFO',
    \"XKB_DEFAULT_LAYOUT=de\"," "$(cat "$cfg")"
expect "one-line env arrays stay one-line" \
  "env = ['RUN_SWAY=true', 'GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*', \"XKB_DEFAULT_LAYOUT=de\"" "$(cat "$cfg")"
expect "a process runner gets no env" 'type = "process"
run_cmd' "$(cat "$cfg")"

# A restart with the same settings changes nothing.
cp "$cfg" "$work/kb.before"
run_init "$state" WOLF_KEYBOARD=de WOLF_KEYBOARD_VARIANT=nodeadkeys WOLF_LOCALE=de_DE.UTF-8 \
  WOLF_TZ=Europe/Berlin >/dev/null
if cmp -s "$cfg" "$work/kb.before"; then ok "a restart with the same settings is a no-op"
else bad "a restart with the same settings is a no-op" "no diff"; fi

# Apps from Wolf Den, and per-app values: what an app sets itself is kept, and a
# docker runner without an env gets one. The base_create_json string mentions
# env too, and must not be touched.
cat >> "$cfg" <<'TOML'

[[profiles.apps]]
title = 'Own TZ'

[profiles.apps.runner]
base_create_json = """
{ "Env": [
env = [ 'NOT=me' ]
] }
"""
env = [ 'TZ=America/New_York', "LANG=en_US.UTF-8" ] # mine
image = 'ghcr.io/example/own:1'
type = 'docker'

[[profiles.apps]]
title = 'No env'

[profiles.apps.runner]
image = 'ghcr.io/example/none:1'
type = 'docker'

[profiles.apps.video]
source = 'x'
TOML
run_init "$state" WOLF_KEYBOARD=de WOLF_LOCALE=de_DE.UTF-8 WOLF_TZ=Europe/Vienna >/dev/null
all=$(cat "$cfg")
expect "a per-app TZ is kept" \
  "env = ['TZ=America/New_York', \"LANG=en_US.UTF-8\", \"XKB_DEFAULT_LAYOUT=de\", \"LANGUAGE=de_DE:de\"] # mine" "$all"
expect "env text inside a string is left alone" "env = [ 'NOT=me' ]" "$all"
expect "a runner without env gets one" "image = 'ghcr.io/example/none:1'
type = 'docker'
env = [\"XKB_DEFAULT_LAYOUT=de\", \"LANG=de_DE.UTF-8\", \"LANGUAGE=de_DE:de\", \"TZ=Europe/Vienna\"]

[profiles.apps.video]" "$all"
# What the last start wrote follows .env: TZ changed, the variant was dropped.
expect "a changed setting is updated" '"TZ=Europe/Vienna"' "$all"
case "$all" in
  *"TZ=Europe/Berlin"*|*"XKB_DEFAULT_VARIANT"*) bad "old values the recipe wrote are replaced or dropped" "no Berlin, no variant" ;;
  *) ok "old values the recipe wrote are replaced or dropped" ;;
esac

# Nothing set: nothing is added.
run_init "$work/none" >/dev/null
case "$(cat "$work/none/cfg/config.toml")" in
  *XKB_DEFAULT_LAYOUT*|*'"LANG='*|*'"TZ='*) bad "no settings, no app env" "untouched env" ;;
  *) ok "no settings, no app env" ;;
esac

for v in 'WOLF_KEYBOARD=de"' 'WOLF_LOCALE=de DE' 'WOLF_TZ=Europe/Berlin|x'; do
  out=$(run_init "$work/badenv" "$v" || true)
  case "$out" in
    *"Invalid ${v%%=*}"*) case "$out" in *"ENTRYPOINT CONTINUED"*) bad "invalid $v aborts" "abort" ;; *) ok "invalid $v aborts" ;; esac ;;
    *) bad "invalid $v aborts" "Invalid ${v%%=*}" ;;
  esac
done

# A session container chowned the shared runtime dir to 1000 with mode 700 (#19):
# the next start hands it back to root:root 0755 so PulseAudio comes up. As a
# non-root user (CI) only the mode can be checked.
rt="$work/run-wolf"
mkdir -p "$rt"; chmod 700 "$rt"
if [ "$(id -u)" -eq 0 ]; then chown 1000:1000 "$rt"; fi
out=$(run_init "$work/rt" XDG_RUNTIME_DIR="$rt")
expect "a taken-over runtime dir is reported" "Resetting $rt" "$out"
expect "a taken-over runtime dir does not stop the start" "ENTRYPOINT CONTINUED" "$out"
if [ "$(stat -c '%a' "$rt")" = 755 ]; then ok "the runtime dir is 0755 again"
else bad "the runtime dir is 0755 again" "755, got $(stat -c '%a' "$rt")"; fi
if [ "$(id -u)" -eq 0 ]; then
  if [ "$(stat -c '%u:%g' "$rt")" = 0:0 ]; then ok "the runtime dir is root:root again"
  else bad "the runtime dir is root:root again" "0:0, got $(stat -c '%u:%g' "$rt")"; fi
  out=$(run_init "$work/rt" XDG_RUNTIME_DIR="$rt")
  case "$out" in
    *Resetting*) bad "a runtime dir that is already right is left alone" "no Resetting" ;;
    *) ok "a runtime dir that is already right is left alone" ;;
  esac
fi
out=$(run_init "$work/rt" XDG_RUNTIME_DIR="$work/does-not-exist")
expect "a missing runtime dir is no error" "ENTRYPOINT CONTINUED" "$out"

# Sourced into the entrypoint's shell, so it must not leak its own variables.
leak=$(env HOST_APPS_STATE_FOLDER="$work/leak" bash -c '
  set -e; gow_log() { :; }; source "$1"
  echo "${wolf_cfg_file-unset} ${wolf_default_cfg-unset} ${wolf_env_want-unset} ${wolf_env_prev-unset} ${wolf_runtime_dir-unset}"' _ "$work/init.sh")
expect "leaves no variables behind" "unset unset unset unset unset" "$leak"

echo
echo "  ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
