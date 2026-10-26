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
# - Every start: give every docker app the keyboard layout, locale and timezone
#   from .env (WOLF_KEYBOARD, WOLF_KEYBOARD_VARIANT, WOLF_LOCALE, WOLF_TZ), so
#   apps added later through Wolf Den get them too. See below for how values an
#   app sets itself are kept.
# - Every start: hand XDG_RUNTIME_DIR back to root:root 0755. It is shared with
#   the session containers, and their 10-setup_user.sh chowns it to PUID:PGID
#   with mode 700; the embedded PulseAudio (root) then refuses to start on the
#   next Wolf restart (#19).

wolf_cfg_file="${HOST_APPS_STATE_FOLDER:-/etc/wolf}/cfg/config.toml"
wolf_default_cfg=/opt/wolf-proxmox/default-config.toml
# What the last start wrote into the apps' env, so the next one can tell its own
# entries from ones set per app.
wolf_env_state="${HOST_APPS_STATE_FOLDER:-/etc/wolf}/cfg/.wolf-proxmox-env"

if [[ ! "${WOLF_IMAGE_TAG:=edge}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid WOLF_IMAGE_TAG: ${WOLF_IMAGE_TAG}" >&2
  return 1
fi
# The values go into TOML strings unescaped, so keep them to what real layouts,
# locales and zone names use.
if [[ ! "${WOLF_KEYBOARD:-}${WOLF_KEYBOARD_VARIANT:-}" =~ ^[A-Za-z0-9_,-]*$ ]]; then
  echo "Invalid WOLF_KEYBOARD / WOLF_KEYBOARD_VARIANT: ${WOLF_KEYBOARD:-} ${WOLF_KEYBOARD_VARIANT:-}" >&2
  return 1
fi
if [[ ! "${WOLF_LOCALE:-}" =~ ^[A-Za-z0-9_.@-]*$ ]]; then
  echo "Invalid WOLF_LOCALE: ${WOLF_LOCALE}" >&2
  return 1
fi
if [[ ! "${WOLF_TZ:-}" =~ ^[A-Za-z0-9_+/-]*$ ]]; then
  echo "Invalid WOLF_TZ: ${WOLF_TZ}" >&2
  return 1
fi

wolf_runtime_dir="${XDG_RUNTIME_DIR:-}"
if [[ -n "$wolf_runtime_dir" && -d "$wolf_runtime_dir" ]] &&
  [[ "$(stat -c '%u:%g:%a' "$wolf_runtime_dir")" != "0:0:755" ]]; then
  gow_log "Resetting ${wolf_runtime_dir} ($(stat -c '%u:%g %a' "$wolf_runtime_dir")) to root:root 0755"
  if ! { chmod 755 "$wolf_runtime_dir" && chown root:root "$wolf_runtime_dir"; }; then
    echo "Could not reset ${wolf_runtime_dir}; PulseAudio may not start" >&2
  fi
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

# The variables the apps read, as KEY=VALUE|... An empty value means "not set
# by this recipe". LANGUAGE is the locale's language list: de_DE.UTF-8 -> de_DE:de.
wolf_lang="${WOLF_LOCALE:-}"
wolf_lang="${wolf_lang%%[.@]*}"
case "$wolf_lang" in
  ""|C|POSIX) wolf_language="" ;;
  *_*) wolf_language="${wolf_lang}:${wolf_lang%%_*}" ;;
  *) wolf_language="$wolf_lang" ;;
esac
wolf_env_want="XKB_DEFAULT_LAYOUT=${WOLF_KEYBOARD:-}|XKB_DEFAULT_VARIANT=${WOLF_KEYBOARD_VARIANT:-}"
wolf_env_want+="|LANG=${WOLF_LOCALE:-}|LANGUAGE=${wolf_language}|TZ=${WOLF_TZ:-}"
wolf_env_prev=""
if [[ -f "$wolf_env_state" ]]; then wolf_env_prev=$(cat "$wolf_env_state"); fi

# Edits each docker runner's env array. A variable the app does not have is
# added; one still holding the value the last start wrote follows .env, or is
# dropped when .env no longer sets it; any other value was set for that app and
# is left alone. Runs in the image's awk, so POSIX awk only.
gow_log "Applying keyboard, locale and timezone to the apps"
if ! awk -v want="$wolf_env_want" -v prev="$wolf_env_prev" '
  function ml_scan(s,   p, q) { # tracks """ / triple-single-quote strings across lines
    while (s != "") {
      if (ml == "") {
        p = index(s, "\"\"\""); q = index(s, SQ SQ SQ)
        if (!p && !q) return
        if (!p || (q && q < p)) { ml = SQ SQ SQ; p = q }
        else ml = "\"\"\""
        s = substr(s, p + 3)
      } else {
        p = index(s, ml)
        if (!p) return
        ml = ""; s = substr(s, p + 3)
      }
    }
  }
  function content(e) { # the text of a TOML string element, quotes removed
    return substr(e, 2, length(e) - 2)
  }
  # Parses the env array that starts on line i into E[1..ne]; sets env_end (last
  # line) and env_rest (what follows the closing bracket on it).
  function parse_env(i,   s, c, j, st, tok) {
    ne = 0; st = ""; tok = ""
    s = L[i]; s = substr(s, index(s, "=") + 1); sub(/^[ \t]*\[/, "", s)
    for (;;) {
      for (j = 1; j <= length(s); j++) {
        c = substr(s, j, 1)
        if (st == SQ) { tok = tok c; if (c == SQ) { E[++ne] = tok; st = "" }; continue }
        if (st == "\"") {
          tok = tok c
          if (c == "\\") { j++; tok = tok substr(s, j, 1) }
          else if (c == "\"") { E[++ne] = tok; st = "" }
          continue
        }
        if (c == SQ || c == "\"") { st = c; tok = c }
        else if (c == "#") break
        else if (c == "]") { env_end = i; env_rest = substr(s, j + 1); return 1 }
      }
      if (st != "" || ++i > n) return 0
      s = L[i]
    }
  }
  function env_key(e) { e = content(e); return index(e, "=") ? substr(e, 1, index(e, "=") - 1) : e }
  function env_val(e) { e = content(e); return substr(e, index(e, "=") + 1) }
  # Applies want/prev to E[]; returns whether anything changed.
  function apply(   k, j, m, changed, seen, F) {
    changed = 0; m = 0
    for (j = 1; j <= ne; j++) {
      k = env_key(E[j])
      if (k in W) {
        seen[k] = 1
        if (k in P && P[k] != "" && env_val(E[j]) == P[k] && W[k] != P[k]) {
          changed = 1
          if (W[k] == "") continue
          E[j] = "\"" k "=" W[k] "\""
        }
      }
      F[++m] = E[j]
    }
    for (j = 1; j <= nk; j++) {
      k = K[j]
      if (W[k] != "" && !(k in seen)) { F[++m] = "\"" k "=" W[k] "\""; changed = 1 }
    }
    ne = m
    for (j = 1; j <= m; j++) E[j] = F[j]
    return changed
  }
  function env_text(indent, multi,   s, j) {
    if (!multi) {
      s = indent "env = ["
      for (j = 1; j <= ne; j++) s = s (j > 1 ? ", " : "") E[j]
      return s "]"
    }
    s = indent "env = ["
    for (j = 1; j <= ne; j++) s = s "\n" indent "    " E[j] (j < ne ? "," : "")
    return s "\n" indent "]"
  }
  # Rewrites the runner table on lines a..b into OUT.
  function runner(a, b,   i, envl, docker, last, indent) {
    envl = 0; docker = 0; last = a
    for (i = a; i <= b; i++) {
      if (L[i] !~ /^[ \t]*$/) last = i
      if (ML[i] != "") continue
      if (L[i] ~ /^[ \t]*type[ \t]*=[ \t]*["\047]docker["\047]/) docker = 1
      if (L[i] ~ /^[ \t]*env[ \t]*=[ \t]*\[/) envl = i
    }
    if (!docker) { for (i = a; i <= b; i++) OUT[++no] = L[i]; return }
    if (!envl) {
      ne = 0
      for (i = a; i <= b; i++) {
        OUT[++no] = L[i]
        if (i == last && apply()) OUT[++no] = env_text("", 0)
      }
      return
    }
    for (i = a; i < envl; i++) OUT[++no] = L[i]
    if (!parse_env(envl)) bad = 1
    else if (apply()) envl = -envl
    if (envl > 0) { for (i = envl; i <= b; i++) OUT[++no] = L[i]; return }
    envl = -envl
    indent = L[envl]; sub(/[^ \t].*$/, "", indent)
    OUT[++no] = env_text(indent, env_end > envl) env_rest
    for (i = env_end + 1; i <= b; i++) OUT[++no] = L[i]
  }
  BEGIN {
    SQ = "\047"
    nk = split(want, T, "|")
    for (j = 1; j <= nk; j++) { K[j] = substr(T[j], 1, index(T[j], "=") - 1); W[K[j]] = substr(T[j], index(T[j], "=") + 1) }
    m = split(prev, T, "|")
    for (j = 1; j <= m; j++) if (index(T[j], "=")) P[substr(T[j], 1, index(T[j], "=") - 1)] = substr(T[j], index(T[j], "=") + 1)
  }
  { L[++n] = $0; ML[n] = ml; ml_scan($0) }
  END {
    for (i = 1; i <= n; i = j) {
      h = L[i]; gsub(/[ \t]/, "", h); sub(/#.*$/, "", h)
      for (j = i + 1; j <= n; j++) if (ML[j] == "" && L[j] ~ /^[ \t]*\[/) break
      if (ML[i] == "" && h == "[profiles.apps.runner]") runner(i, j - 1)
      else for (k = i; k < j; k++) OUT[++no] = L[k]
    }
    if (bad) { print "config.toml: cannot read an app'"'"'s env array; leaving it as it is" > "/dev/stderr" }
    for (i = 1; i <= no; i++) print OUT[i]
  }
' "$wolf_cfg_file" >"${wolf_cfg_file}.tmp"; then
  rm -f "${wolf_cfg_file}.tmp"
  return 1
fi
mv -f "${wolf_cfg_file}.tmp" "$wolf_cfg_file"
echo "$wolf_env_want" >"$wolf_env_state"

unset wolf_runtime_dir wolf_cfg_file wolf_default_cfg wolf_env_state wolf_lang wolf_language wolf_env_want wolf_env_prev
