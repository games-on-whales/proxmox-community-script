#!/usr/bin/env bash
#
# Exercises install.sh's ensure_nvidia_cdi against a faked host, so the NVIDIA
# passthrough prerequisite can be verified without a PVE node or a GPU. The
# function is extracted from install.sh rather than restated here: a copy would
# keep passing after install.sh changed. Run from the repo root:
#
#   bash tests/nvidia-cdi-dryrun.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n       expected: %s\n' "$1" "$2"; fail=$((fail+1)); }

# Runs ensure_nvidia_cdi against stub executables on PATH — resolved the way a
# real host resolves them, so `command -v nvidia-ctk` means what it means in
# install.sh. /etc/cdi is rewritten into a scratch dir.
#   $@ = env assignments
#     HAVE_CTK=1     nvidia-ctk is already installed (no apt work expected)
#     CTK_INSTALLS=0 the apt install does not put nvidia-ctk on PATH
#     GEN_FAILS=1    nvidia-ctk cdi generate exits non-zero
#     SPEC_EMPTY=1   generate writes a spec carrying no device nodes
run_cdi() {
  local fake; fake=$(mktemp -d)
  local bin="$fake/bin"; mkdir -p "$bin" "$fake/etc-cdi"

  # apt-get install is what puts nvidia-ctk on PATH, unless CTK_INSTALLS=0.
  cat > "$bin/apt-get" <<EOF
#!/usr/bin/env bash
echo "APT \$1"
[ "\$1" = install ] && [ "\${CTK_INSTALLS:-1}" = 1 ] && install -m 0755 "$bin/nvidia-ctk.real" "$bin/nvidia-ctk"
exit 0
EOF

  # The generator writes the spec that install.sh then inspects. It announces
  # itself on stderr because install.sh sends the generator's stdout to
  # /dev/null — asserting on stdout here would silently observe nothing.
  cat > "$bin/nvidia-ctk.real" <<EOF
#!/usr/bin/env bash
echo "NVIDIA-CTK \$*" >&2
[ "\${GEN_FAILS:-0}" = 1 ] && exit 1
if [ "\${SPEC_EMPTY:-0}" = 1 ]; then
  echo '{"cdiVersion":"0.5.0","devices":[]}' > "$fake/etc-cdi/nvidia.json"
else
  echo '{"cdiVersion":"0.5.0","containerEdits":{"deviceNodes":[{"path":"/dev/nvidiactl"}]}}' > "$fake/etc-cdi/nvidia.json"
fi
exit 0
EOF

  printf '#!/usr/bin/env bash\necho "gpgkey-or-list-content"\n' > "$bin/curl"
  printf '#!/usr/bin/env bash\ncat >/dev/null\necho "GPG $*"\n'  > "$bin/gpg"
  chmod +x "$bin"/*
  # CTK_PRESENT models a host that already carries the toolkit, so the stub has
  # to exist on PATH before the function runs — not just as an env flag.
  case " $* " in *" CTK_PRESENT=1 "*) cp "$bin/nvidia-ctk.real" "$bin/nvidia-ctk" ;; esac

  local script="$fake/run.sh"
  cat > "$script" <<'HARNESS'
set -euo pipefail
YW=''; GN=''; RD=''; BL=''; CL=''
msg_info() { echo " > $*"; }
msg_ok()   { echo " ok $*"; }
msg_err()  { echo " ERR $*" >&2; }
die()      { msg_err "$*"; exit 1; }
HARNESS

  # The function under test, lifted verbatim from install.sh — anchored on its
  # definition line and closing brace, so an edit there lands in this test.
  # Only host paths are rewritten: /etc/cdi into the scratch dir, and the apt
  # sources/keyring writes (root-owned) into it too.
  sed -n '/^ensure_nvidia_cdi() {$/,/^}$/p' install.sh \
    | sed -e "s#/etc/cdi#$fake/etc-cdi#g" \
          -e "s#/usr/share/keyrings#$fake/keyrings#g" \
          -e "s#/etc/apt/sources.list.d#$fake/apt-sources#g" >> "$script"
  echo 'ensure_nvidia_cdi' >> "$script"
  mkdir -p "$fake/apt-sources"

  env "$@" PATH="$bin:$PATH" bash "$script" 2>&1 || true
  rm -rf "$fake"
}

expect() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "$2" ;; esac; }
reject() { case "$3" in *"$2"*) bad "$1" "not: $2" ;; *) ok "$1" ;; esac; }

echo "ensure_nvidia_cdi"

# A host with no toolkit gets one, then a spec.
out=$(run_cdi HAVE_CTK=0)
expect "missing toolkit is installed"   "APT install"                      "$out"
expect "the CDI spec is generated"      "NVIDIA-CTK cdi generate"          "$out"
expect "success is reported"            "NVIDIA CDI spec written"          "$out"

# A host that already has it skips the apt work but still refreshes the spec,
# so a driver upgrade cannot leave a stale spec behind.
out=$(run_cdi HAVE_CTK=1 CTK_PRESENT=1)
reject "present toolkit is not reinstalled" "APT install"                  "$out"
expect "the spec is refreshed anyway"       "NVIDIA-CTK cdi generate"      "$out"

# The failure modes must abort the install, not fall through to a GPU-less CT.
out=$(run_cdi CTK_INSTALLS=0)
expect "install that yields no nvidia-ctk aborts" "still not on PATH"      "$out"
reject "and does not go on to generate"           "cdi generate"           "$out"

out=$(run_cdi CTK_PRESENT=1 GEN_FAILS=1)
expect "a failed generate aborts" "nvidia-ctk cdi generate failed"         "$out"
reject "and is not reported as success" "NVIDIA CDI spec written"          "$out"

# The case that produced the original bug: a spec that parses but injects
# nothing, leaving a CT with /dev/dri but no driver — Wolf then picks the NVENC
# path and panics in eglInitialize, with no mention of the GPU anywhere.
out=$(run_cdi CTK_PRESENT=1 SPEC_EMPTY=1)
expect "a spec with no device nodes aborts" "declares no device nodes"     "$out"
reject "and is not reported as success" "NVIDIA CDI spec written"          "$out"


# Runs the GPU-overlay selection block (which calls ensure_nvidia_cdi).
#   $1 = RENDER_VENDOR,  $2 = 1 if nvidia-smi answers
run_overlay() {
  local vendor="$1" smi_ok="$2"
  local fake; fake=$(mktemp -d); local bin="$fake/bin"; mkdir -p "$bin"
  if [ "$smi_ok" = 1 ]; then
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/nvidia-smi"; chmod +x "$bin/nvidia-smi"
  fi
  local script="$fake/run.sh"
  cat > "$script" <<HARNESS
set -euo pipefail
YW=''; GN=''; RD=''; BL=''; CL=''
msg_info() { echo " > \$*"; }
msg_ok()   { echo " ok \$*"; }
msg_err()  { echo " ERR \$*" >&2; }
die()      { msg_err "\$*"; exit 1; }
# Stand in for the real prerequisite step, which has its own tests above.
ensure_nvidia_cdi() { echo "ENSURE-CDI"; }
RENDER_VENDOR="$vendor"; RENDER_NODE=/dev/dri/renderD128
HARNESS
  sed -n '/^# The NVIDIA overlay applies only/,/^fi$/p' install.sh >> "$script"
  echo 'echo "COMPOSE ${COMPOSE_ARGS[*]}"' >> "$script"
  env PATH="$bin:/usr/bin:/bin" bash "$script" 2>&1 || true
  rm -rf "$fake"
}

echo
echo "GPU overlay selection"

out=$(run_overlay NVIDIA 1)
expect "a working NVIDIA driver adds the overlay" "COMPOSE -f docker-compose.yml -f docker-compose.nvidia.yml" "$out"
expect "and runs the CDI prerequisite"            "ENSURE-CDI"                      "$out"

# The user's case: an NVIDIA card selected on a host whose driver isn't loaded.
# Installing anyway produces a CT that cannot stream, so this must abort.
out=$(run_overlay NVIDIA 0)
expect "NVIDIA without a driver aborts"    "Refusing to install"                    "$out"
expect "and says how to fix it"            "modprobe nvidia_drm modeset=1"          "$out"
reject "and does not fall back to base"    "COMPOSE"                                "$out"
reject "and does not run the CDI step"     "ENSURE-CDI"                             "$out"

out=$(run_overlay AMD 0)
expect "a non-NVIDIA GPU uses the base profile" "COMPOSE -f docker-compose.yml"     "$out"
reject "and does not run the CDI step"          "ENSURE-CDI"                        "$out"

echo
echo "  ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
