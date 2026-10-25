#!/usr/bin/env bash
#
# Exercises nvidia-cdi.sh's 32-bit library handling against a faked driver: a
# stub nvidia-smi/nvidia-ctk and a fake .run carrying real i386 ELF objects
# (built here with `cc -m32`), so the SONAME links come from the real ldconfig.
# No GPU or Proxmox host required. Run from the repo root:
#
#   bash tests/nvidia-lib32-dryrun.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n       expected: %s\n' "$1" "$2"; fail=$((fail+1)); }
expect() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "$2" ;; esac; }
reject() { case "$3" in *"$2"*) bad "$1" "not: $2" ;; *) ok "$1" ;; esac; }
same()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2, got $3"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# so <out> <soname> <-m32|-m64> — a minimal shared object with that SONAME.
echo 'int nv;' > "$T/x.c"
so() { cc "$3" -shared -fPIC -nostdlib -Wl,-soname,"$2" -o "$1" "$T/x.c" 2>/dev/null; }
if ! so "$T/probe.so" libprobe.so.1 -m32; then
  echo "SKIP: no 32-bit C toolchain (cc -m32) to build i386 fixtures"
  exit 0
fi

# make_run <version> — a fake NVIDIA-Linux-x86_64-<version>.run. Its 32/ dir
# holds the driver's own libraries, a glvnd loader, a library from another
# driver version and a 64-bit object misfiled under 32/.
make_run() {
  local v="$1" src="$T/run-$1/32"
  mkdir -p "$src"
  so "$src/libGLX_nvidia.so.$v"     libGLX_nvidia.so.0  -m32
  so "$src/libcuda.so.$v"           libcuda.so.1        -m32
  so "$src/libnvidia-glcore.so.$v"  "libnvidia-glcore.so.$v" -m32
  so "$src/libGL.so.1.7.0"          libGL.so.1          -m32
  so "$src/libnvidia-old.so.470.1"  libnvidia-old.so.1  -m32
  so "$src/libnvidia-wrong.so.$v"   libnvidia-wrong.so.1 -m64
  ln -s "libcuda.so.$v" "$src/libcuda.so"
  cat > "$T/NVIDIA-Linux-x86_64-$v.run" <<EOF
#!/bin/sh
echo "RUN \$*" >> "$T/calls.log"
[ "\$1" = --extract-only ] && [ "\$2" = --target ] || exit 1
mkdir -p "\$3" && cp -a "$T/run-$v/32" "\$3/"
EOF
}
make_run 580.1.2
make_run 590.0.1

# Stubs. nvidia-ctk writes a 64-bit spec for CTK_VER (default: the driver).
mkdir -p "$T/bin"
cat > "$T/bin/nvidia-smi" <<EOF
#!/bin/sh
cat "$T/driver"
EOF
cat > "$T/bin/nvidia-ctk" <<EOF
#!/bin/sh
[ "\${GEN_FAILS:-0}" = 1 ] && exit 1
v=\${CTK_VER:-\$(cat "$T/driver")}
out=\$(printf '%s\n' "\$@" | sed -n 's/^--output=//p')
cat > "\$out" <<SPEC
{"cdiVersion":"0.5.0","kind":"nvidia.com/gpu",
 "devices":[{"name":"all","containerEdits":{"deviceNodes":[{"path":"/dev/nvidia0"}]}}],
 "containerEdits":{"deviceNodes":[{"path":"/dev/nvidiactl"}],
  "mounts":[{"hostPath":"/usr/lib/x86_64-linux-gnu/libcuda.so.\$v","containerPath":"/usr/lib/x86_64-linux-gnu/libcuda.so.\$v","options":["ro","nosuid","nodev","rbind","rprivate"]}],
  "hooks":[{"hookName":"createContainer","path":"/usr/bin/nvidia-cdi-hook","args":["nvidia-cdi-hook","create-symlinks","--link","libcuda.so.1::/usr/lib/x86_64-linux-gnu/libcuda.so"]}]}}
SPEC
EOF
# Downloads come from the fake .runs, or fail with CURL_FAILS=1.
cat > "$T/bin/curl" <<EOF
#!/bin/sh
echo "CURL \$*" >> "$T/calls.log"
[ "\${CURL_FAILS:-0}" = 1 ] && exit 22
out=""; for a; do [ "\$prev" = -o ] && out="\$a"; prev="\$a"; done
cp "$T/\${out##*/}" "\$out"
EOF
chmod +x "$T/bin"/* "$T"/*.run

SPEC="$T/cdi/nvidia.json"
LIBS="$T/lib32"
run() { # run <driver version> [env...]
  echo "$1" > "$T/driver"; shift
  : > "$T/calls.log"
  env "$@" PATH="$T/bin:$PATH" WOLF_CDI_SPEC="$SPEC" WOLF_LIB32_ROOT="$LIBS" \
    TMPDIR="$T" bash nvidia-cdi.sh 2>&1 && echo "EXIT 0" || echo "EXIT $?"
}
# q <perl expr over $e (containerEdits)> — query the written spec.
q() { perl -MJSON::PP -e 'local $/; open my $f, "<", $ARGV[0] or die;
        my $e = decode_json(<$f>)->{containerEdits}; print eval $ARGV[1]' "$SPEC" "$1"; }
i386_mounts() { q 'join " ", sort map { $_->{containerPath} =~ m{^/usr/lib/i386-linux-gnu/(.*)} ? $1 : () } @{$e->{mounts}}'; }
i386_links()  { q 'join " ", sort grep { m{::/usr/lib/i386-linux-gnu/} } map { @{$_->{args}} } @{$e->{hooks}}'; }

echo "32-bit libraries"

out=$(run 580.1.2)
expect "a fresh host succeeds"               "EXIT 0"                         "$out"
expect "it downloads the running driver's .run" "580.1.2/NVIDIA-Linux-x86_64-580.1.2.run" "$(cat "$T/calls.log")"
same   "only the driver's 32-bit libraries are mounted" \
       "libGLX_nvidia.so.580.1.2 libcuda.so.580.1.2 libnvidia-glcore.so.580.1.2" "$(i386_mounts)"
same   "each SONAME gets a link; a full-version SONAME needs none" \
       "libGLX_nvidia.so.580.1.2::/usr/lib/i386-linux-gnu/libGLX_nvidia.so.0 libcuda.so.580.1.2::/usr/lib/i386-linux-gnu/libcuda.so.1" \
       "$(i386_links)"
same   "libraries are mounted from the version's own directory" \
       "$LIBS/580.1.2/libcuda.so.580.1.2" \
       "$(q '(map { $_->{hostPath} } grep { $_->{containerPath} =~ /i386.*libcuda/ } @{$e->{mounts}})[0]')"
same   "the 64-bit mounts are nvidia-ctk's, untouched" \
       "/usr/lib/x86_64-linux-gnu/libcuda.so.580.1.2" \
       "$(q 'join " ", map { $_->{containerPath} } grep { $_->{containerPath} !~ /i386/ } @{$e->{mounts}}')"
same   "and so is its 64-bit symlink hook" "libcuda.so.1::/usr/lib/x86_64-linux-gnu/libcuda.so" \
       "$(q '$e->{hooks}[0]{args}[3]')"

before=$(cat "$SPEC")
out=$(run 580.1.2)
expect "a re-run succeeds"                   "EXIT 0"                         "$out"
reject "and does not download again"         "CURL"                           "$(cat "$T/calls.log")"
same   "and writes the same spec — nothing is duplicated" "$before" "$(cat "$SPEC")"

out=$(run 590.0.1)
expect "a driver upgrade fetches the new .run" "590.0.1/NVIDIA-Linux-x86_64-590.0.1.run" "$(cat "$T/calls.log")"
same   "only the new version's libraries are mounted" \
       "libGLX_nvidia.so.590.0.1 libcuda.so.590.0.1 libnvidia-glcore.so.590.0.1" "$(i386_mounts)"
same   "and the old version's directory is gone" "590.0.1" "$(ls "$LIBS")"

# A local .run for a different driver than the one running yields nothing.
rm -rf "$LIBS"
out=$(run 590.0.1 WOLF_NVIDIA_RUN="$T/NVIDIA-Linux-x86_64-580.1.2.run")
expect "a .run for another version is refused" "has no 32-bit libraries for driver 590.0.1" "$out"
expect "but the 64-bit spec is still written" "EXIT 0"                         "$out"
same   "with no 32-bit entries"              ""                               "$(i386_mounts)"

out=$(run 590.0.1 WOLF_NVIDIA_RUN="$T/NVIDIA-Linux-x86_64-590.0.1.run")
reject "a matching local .run is used without a download" "CURL"             "$(cat "$T/calls.log")"
same   "and supplies the libraries" \
       "libGLX_nvidia.so.590.0.1 libcuda.so.590.0.1 libnvidia-glcore.so.590.0.1" "$(i386_mounts)"

rm -rf "$LIBS"
out=$(run 580.1.2 CURL_FAILS=1)
expect "a failed download warns"             "continuing without 32-bit libraries" "$out"
expect "and still writes the 64-bit spec"    "EXIT 0"                         "$out"
same   "with no 32-bit entries"              ""                               "$(i386_mounts)"
same   "and leaves no partial directory"     ""                               "$(ls "$LIBS" 2>/dev/null)"

# Two halves of different drivers must not be combined.
out=$(run 580.1.2 CTK_VER=575.0.0)
expect "a 64-bit spec for another driver aborts" "no 64-bit libraries for driver 580.1.2" "$out"
reject "and is not reported as written"      "wrote"                          "$out"

before=$(cat "$SPEC")
out=$(run 580.1.2 GEN_FAILS=1)
expect "a failed generate aborts"            "nvidia-ctk cdi generate failed" "$out"
same   "and leaves the previous spec in place" "$before" "$(cat "$SPEC")"
same   "with no temp files in /etc/cdi"      "nvidia.json"                    "$(ls -A "$T/cdi")"

out=$(run 580.1.2 WOLF_NVIDIA_LIB32=0)
expect "opting out succeeds"                 "EXIT 0"                         "$out"
same   "with no 32-bit entries"              ""                               "$(i386_mounts)"
same   "and the staged libraries removed"    "no"                             "$([ -e "$LIBS" ] && echo yes || echo no)"

echo
echo "  ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
