#!/usr/bin/env bash
#
# wolf-nvidia-cdi — (re)generate /etc/cdi/nvidia.json for docker-lxc-daemon,
# including the NVIDIA 32-bit driver libraries.
#
# Installed by install.sh as /usr/local/sbin/wolf-nvidia-cdi and run at every
# boot by wolf-nvidia-cdi.service, so a driver upgrade cannot leave a spec that
# binds libraries which no longer exist. Re-run it by hand after changing the
# driver without a reboot.
#
# Why 32-bit: `nvidia-ctk cdi generate` emits only the 64-bit driver, and a
# Proxmox host has no i386 multiarch, so the .run installer skips the 32-bit
# libraries entirely. Steam's GPU probe and every 32-bit GL/Vulkan program in a
# session then fall back to llvmpipe — Steam builds its shader pre-cache for the
# software renderer, and 32-bit games render on the CPU.
#
# The 32-bit libraries come from the .run of exactly the running driver version,
# extracted (never installed) into a per-version directory. Only files carrying
# that version's suffix are taken, plus the EGL platform libraries shipped in the
# same package, so a stale library from an older driver can never be mixed in,
# and directories for other versions are removed.
#
# The spec is always rebuilt from a fresh `nvidia-ctk cdi generate` and only then
# extended, so there is nothing to clean up from a previous run, and the 64-bit
# entries are exactly what nvidia-ctk wrote.
#
# Environment:
#   WOLF_NVIDIA_LIB32=0     skip the 32-bit libraries (64-bit spec only); the
#                           unit reads it from /etc/default/wolf-nvidia-cdi
#   WOLF_NVIDIA_RUN=<path>  use this local NVIDIA-Linux-x86_64-<ver>.run instead
#                           of downloading it from download.nvidia.com
#
set -euo pipefail

CDI_SPEC="${WOLF_CDI_SPEC:-/etc/cdi/nvidia.json}"
LIB32_ROOT="${WOLF_LIB32_ROOT:-/var/lib/wolf-proxmox/nvidia-lib32}"
LIB32_CT_DIR=/usr/lib/i386-linux-gnu
NVIDIA_DOWNLOAD="https://download.nvidia.com/XFree86/Linux-x86_64"

log() { echo "wolf-nvidia-cdi: $*" >&2; }
die() { log "$*"; exit 1; }

# The version of the driver that is actually answering, not whatever .run was
# installed last — a spec for an upgraded-but-not-reloaded driver is no use.
driver_version() {
  local v
  v=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d '[:space:]') || v=""
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)+$ ]] || return 1
  echo "$v"
}

# is_elf32 <file> — ELF class byte (offset 4) is 1 for 32-bit objects.
is_elf32() {
  [ "$(head -c 4 "$1" 2>/dev/null | od -An -c | tr -d ' ')" = '177ELF' ] &&
    [ "$(od -An -tu1 -j4 -N1 "$1" | tr -d ' ')" = 1 ]
}

# stage_lib32 <version> — make ${LIB32_ROOT}/<version> hold that driver's
# NVIDIA-specific 32-bit libraries plus their SONAME links. Reuses a complete
# directory; never touches the host's installed driver.
stage_lib32() {
  [ -f "${LIB32_ROOT}/$1/.complete" ] && return 0
  # The extracted .run is several hundred MB: keep it out of /etc.
  local work rc=0
  work=$(mktemp -d "${TMPDIR:-/var/tmp}/wolf-nvidia-lib32.XXXXXX")
  extract_lib32 "$1" "$work" || rc=$?
  rm -rf "$work"
  return "$rc"
}

# Runs under `||`, where set -e is off: every step checks its own result.
extract_lib32() {
  local ver="$1" work="$2" dir="${LIB32_ROOT}/$1"
  local run="${WOLF_NVIDIA_RUN:-}"
  if [ -z "$run" ]; then
    run="${work}/NVIDIA-Linux-x86_64-${ver}.run"
    log "downloading NVIDIA-Linux-x86_64-${ver}.run for its 32-bit libraries"
    curl -fsSL --connect-timeout 20 -o "$run" \
      "${NVIDIA_DOWNLOAD}/${ver}/NVIDIA-Linux-x86_64-${ver}.run" ||
      { log "could not download the ${ver} driver package"; return 1; }
  fi
  [ -f "$run" ] || { log "${run}: no such file"; return 1; }

  # makeself verifies its own checksum on extraction.
  sh "$run" --extract-only --target "${work}/x" >/dev/null ||
    { log "could not extract ${run}"; return 1; }
  [ -d "${work}/x/32" ] || { log "${run} carries no 32-bit libraries"; return 1; }

  # Only the driver's own libraries: they carry its exact version as a suffix.
  # That rules out the glvnd loaders (libGL, libEGL, ... — the app image ships
  # its own) and libOpenCL, and refuses a .run for any other driver version.
  local partial="${dir}.partial" f n=0
  rm -rf "$partial" && mkdir -p "$partial" || return 1
  for f in "${work}/x/32/"*".so.${ver}"; do
    [ -f "$f" ] && [ ! -L "$f" ] && is_elf32 "$f" || continue
    install -m 0644 "$f" "${partial}/" || return 1
    n=$((n + 1))
  done
  if [ "$n" -eq 0 ]; then
    rm -rf "$partial"
    log "${run} has no 32-bit libraries for driver ${ver}"
    return 1
  fi
  # The EGL platform libraries (gbm, wayland, xcb, xlib) carry their own version
  # numbers; that they ship in this very package is what ties them to the driver.
  for f in "${work}/x/32/"libnvidia-egl-*.so.*; do
    [ -f "$f" ] && [ ! -L "$f" ] && is_elf32 "$f" || continue
    install -m 0644 "$f" "${partial}/" || return 1
    n=$((n + 1))
  done
  # SONAME links (libGLX_nvidia.so.0 -> libGLX_nvidia.so.<ver>, ...), read from
  # each library's own DT_SONAME rather than guessed from its name.
  ldconfig -n "$partial" || { log "ldconfig could not read the 32-bit libraries"; return 1; }

  rm -rf "$dir" && touch "${partial}/.complete" && mv "$partial" "$dir" || return 1
  log "staged ${n} 32-bit libraries for driver ${ver} in ${dir}"
}

# add_lib32 <spec> <lib dir> <version> — append each library as a mount at the
# container's i386 multiarch path, and its SONAME link to a create-symlinks
# hook. docker-lxc-daemon turns these into lxc.mount.entry lines and its mount
# hook, which also registers the directory with the container's ldconfig.
add_lib32() {
  perl -MJSON::PP -e '
    my ($spec, $dir, $ver, $ctdir) = @ARGV;
    open my $in, "<", $spec or die "$spec: $!\n";
    my $d = JSON::PP->new->decode(do { local $/; <$in> });
    close $in;
    my $e = $d->{containerEdits} //= {};
    # A fresh nvidia-ctk spec has nothing here; anything that does is not ours
    # to replace, so refuse rather than shadow it.
    for my $m (@{ $e->{mounts} // [] }) {
      die "spec already mounts $m->{containerPath}\n"
        if index($m->{containerPath} // "", "$ctdir/") == 0;
    }
    # The 64-bit libraries must be the same driver, or the two halves disagree.
    grep { ($_->{hostPath} // "") =~ /\.so\.\Q$ver\E$/ } @{ $e->{mounts} // [] }
      or die "spec has no 64-bit libraries for driver $ver\n";

    opendir my $dh, $dir or die "$dir: $!\n";
    my @names = sort grep { !/^\./ } readdir $dh;
    closedir $dh;
    my (%lib, @links);
    for my $f (@names) {
      # The directory is staged per driver version, from the .run of that version.
      next if -l "$dir/$f" || !-f _;
      $lib{$f} = 1;
      push @{ $e->{mounts} }, {
        hostPath => "$dir/$f", containerPath => "$ctdir/$f",
        options  => [qw(ro nosuid nodev rbind rprivate)],
      };
    }
    for my $f (@names) {
      next unless -l "$dir/$f";
      my $t = readlink "$dir/$f";
      push @links, "--link", "${t}::$ctdir/$f" if $lib{$t};
    }
    push @{ $e->{hooks} }, {
      hookName => "createContainer", path => "/usr/bin/nvidia-cdi-hook",
      args => ["nvidia-cdi-hook", "create-symlinks", @links],
    } if @links;

    open my $out, ">", $spec or die "$spec: $!\n";
    print $out JSON::PP->new->canonical->pretty->encode($d);
    close $out or die "$spec: $!\n";
    printf STDERR "wolf-nvidia-cdi: added %d 32-bit libraries and %d links\n",
      scalar(keys %lib), @links / 2;
  ' "$@" "$LIB32_CT_DIR"
}

ver=$(driver_version) ||
  die "nvidia-smi is not answering — is the driver loaded (nvidia-drm modeset=1)?"
command -v nvidia-ctk >/dev/null 2>&1 ||
  die "nvidia-ctk not found — install nvidia-container-toolkit-base."

# Build next to the live spec and swap it in whole: the daemon re-reads the file
# whenever its mtime changes, and must never see a half-written one.
mkdir -p "$(dirname "$CDI_SPEC")"
tmpdir=$(mktemp -d "$(dirname "$CDI_SPEC")/.wolf-nvidia-cdi.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT
new="${tmpdir}/nvidia.json"

nvidia-ctk cdi generate --format=json --output="$new" >/dev/null ||
  die "nvidia-ctk cdi generate failed — is the driver loaded (nvidia-drm modeset=1)?"
# An empty spec parses cleanly and injects nothing. Insist on device nodes.
grep -q '"deviceNodes"' "$new" ||
  die "the generated spec declares no device nodes — the CT would start without a GPU."

if [ "${WOLF_NVIDIA_LIB32:-1}" = 1 ]; then
  if stage_lib32 "$ver"; then
    add_lib32 "$new" "${LIB32_ROOT}/${ver}" "$ver" ||
      die "could not add the 32-bit libraries to the spec"
  else
    # 64-bit GPU access is what Wolf needs to stream at all; don't withhold it
    # over the 32-bit extras.
    log "WARNING: continuing without 32-bit libraries — Steam and 32-bit games will use llvmpipe"
  fi
  # Libraries for any other driver version are stale by definition.
  if [ -d "$LIB32_ROOT" ]; then
    find "$LIB32_ROOT" -mindepth 1 -maxdepth 1 ! -name "$ver" -exec rm -rf {} +
  fi
else
  rm -rf "$LIB32_ROOT"
fi

chmod 0644 "$new"
mv -f "$new" "$CDI_SPEC"
log "wrote ${CDI_SPEC} for driver ${ver}"
