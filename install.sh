#!/usr/bin/env bash
#
# Wolf on Proxmox (LXC2Docker) — one-line host installer.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/games-on-whales/proxmox-community-script/main/install.sh)"
#
# Installs docker-lxc-daemon on the Proxmox VE host, sets up the virtual-input
# and runtime prerequisites, and brings up Games-on-Whales Wolf (+ the Wolf Den
# UI). Wolf streams virtual desktops and applications to Moonlight clients; each
# session runs as a sibling Proxmox CT through the daemon.
#
# Non-interactive: preset DLD_STORAGE, WOLF_LAN_IP (CIDR), WOLF_DISK_SIZE,
# WOLF_CPUS, WOLF_MEMORY, WOLF_RENDER_NODE and optionally WOLF_BRIDGE
# ("name=prefix/subnet:gateway") in the environment. Anything left unset is
# prompted for on a terminal, or takes its default when there is no terminal.
#
set -euo pipefail

YW=$'\033[33m'; GN=$'\033[1;92m'; RD=$'\033[01;31m'; BL=$'\033[36m'; CL=$'\033[m'
msg_info() { echo -e " ${YW}▶${CL} $*"; }
msg_ok()   { echo -e " ${GN}✓${CL} $*"; }
msg_err()  { echo -e " ${RD}✗${CL} $*" >&2; }
die()      { msg_err "$*"; exit 1; }
# Report the command that failed, not just where: a bare line number sends
# people to a script they have to fetch and count through before they can say
# what went wrong.
trap 'msg_err "install failed (line $LINENO): $BASH_COMMAND"' ERR

REPO_RAW="https://raw.githubusercontent.com/games-on-whales/proxmox-community-script/main"
DAEMON_REPO="games-on-whales/LXC2Docker"
DEST="${WOLF_DEST:-/opt/wolf-proxmox}"

# ---------- prompt helpers ----------
# Same selection model as the Wolf quickstart scripts this installer descends
# from (games-on-whales/wolf, quickstart/common.sh): a numbered list with a
# default of 1, single-candidate lists auto-selected, and an env override that
# must match a real candidate or abort. With no terminal every question takes
# its default, so the script also runs unattended.

# Prompt user to pick from a numbered list. Returns 0-based index in CHOICE_IDX.
# Usage: prompt_choice <prompt_text> <array_of_labels>
prompt_choice() {
  local prompt_text="$1"; shift
  local labels=("$@")

  echo ""
  local i
  for i in "${!labels[@]}"; do
    printf "  %d) %s\n" $((i + 1)) "${labels[$i]}"
  done
  echo ""

  local choice
  while true; do
    if [ -t 0 ]; then read -rp "${prompt_text} [1]: " choice; else choice=""; fi
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#labels[@]} )); then
      break
    fi
    echo "Invalid selection. Enter a number between 1 and ${#labels[@]}."
  done
  CHOICE_IDX=$((choice - 1))
}

# Prompt for a whole number in [1, max], re-asking until the answer is one.
# Usage: prompt_number <text> <default> <max> [unit]
#
# <unit> is carried through the prompt, the default and the error, so every size
# question says what it is measured in. A matching suffix on the answer is
# ignored — "100", "100G" and "100 GB" all mean 100 — and anything else re-asks
# rather than silently taking the default, which is how a mistyped size used to
# turn into a volume nobody asked for.
prompt_number() {
  local prompt_text="$1" default="$2" max="$3" unit="${4:-}" value
  local shown="${unit:+ $unit}"
  while true; do
    if [ -t 0 ]; then read -rp "${prompt_text} [${default}${shown}]: " value; else value=""; fi
    value="${value//[[:space:]]/}"                       # "100 GB"
    # A unit is only a unit when it trails a number: "100G" is 100, but "big" is
    # not a size at all and has to come back as one so the question re-asks.
    if [[ "$value" =~ ^([0-9]+)[A-Za-z]*$ ]]; then value="${BASH_REMATCH[1]}"; fi
    value="${value:-$default}"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= max )); then
      break
    fi
    echo "Invalid value. Enter a whole number between 1 and ${max}${shown}."
    [ -t 0 ] || die "No terminal to re-ask on — fix the preset value and re-run."
  done
  NUMBER_VALUE="$value"
}

cat <<'BANNER'
   Wolf on Proxmox — Virtual desktops & apps to Moonlight, backed by LXC2Docker
   Sessions run as sibling Proxmox CTs. https://github.com/games-on-whales/wolf
BANNER
echo

# ---------- preflight ----------
[ "$(id -u)" -eq 0 ] || die "Run as root on the Proxmox VE host."
command -v pveversion >/dev/null 2>&1 || die "Must run on a Proxmox VE host (pveversion not found)."
command -v curl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y curl; }

# ---------- 0. gather settings ----------
# Ask everything up front so the rest of the install runs unattended.

# --- Proxmox storage for the Wolf CT and every session CT ---
# Candidates are the active rootdir storages, labelled "name (type, N GB free)".
# The free figure also bounds the disk question below; pvesm reports 1K blocks.
STORAGE_NAMES=(); STORAGE_FREE_GB=(); STORAGE_TYPES=(); storage_labels=()
while IFS='|' read -r name type enabled free_gb; do
  [[ "$enabled" == "1" ]] || continue
  STORAGE_NAMES+=("$name"); STORAGE_FREE_GB+=("$free_gb"); STORAGE_TYPES+=("$type")
  storage_labels+=("${name} (${type}, ${free_gb} GB free)")
done < <(pvesm status --content rootdir 2>/dev/null |
  awk 'NR>1 {printf "%s|%s|%s|%d\n", $1, $2, ($3=="active"?"1":"0"), $6/1048576}')

[ "${#STORAGE_NAMES[@]}" -gt 0 ] || die "No active Proxmox storage with rootdir content found"

STORAGE="${DLD_STORAGE:-}"
storage_idx=-1
if [ -n "$STORAGE" ]; then
  for i in "${!STORAGE_NAMES[@]}"; do
    [ "${STORAGE_NAMES[$i]}" = "$STORAGE" ] && { storage_idx=$i; break; }
  done
  [ "$storage_idx" -ge 0 ] || die "Storage ${STORAGE} not found. Available: ${STORAGE_NAMES[*]}"
  msg_info "Using storage: ${storage_labels[$storage_idx]}"
elif [ "${#STORAGE_NAMES[@]}" -eq 1 ]; then
  storage_idx=0
  msg_info "Using storage: ${storage_labels[0]}"
else
  prompt_choice "Select storage for the Wolf CT" "${storage_labels[@]}"
  storage_idx="$CHOICE_IDX"
  msg_info "Selected storage: ${storage_labels[$storage_idx]}"
fi
STORAGE="${STORAGE_NAMES[$storage_idx]}"
STORAGE_GB="${STORAGE_FREE_GB[$storage_idx]}"
STORAGE_TYPE="${STORAGE_TYPES[$storage_idx]}"

# --- Wolf CT disk, in GB (the Steam library / game data lives here) ---
[ "$STORAGE_GB" -gt 0 ] || die "Storage ${STORAGE} reports no free space."
CT_DISK="${WOLF_DISK_SIZE:-}"; CT_DISK="${CT_DISK%[Gg]}"
if [ -n "$CT_DISK" ]; then
  [[ "$CT_DISK" =~ ^[0-9]+$ ]] && [ "$CT_DISK" -ge 1 ] && [ "$CT_DISK" -le "$STORAGE_GB" ] ||
    die "WOLF_DISK_SIZE=${WOLF_DISK_SIZE} does not fit the ${STORAGE_GB} GB free on ${STORAGE}."
else
  default_disk=100; [ "$default_disk" -le "$STORAGE_GB" ] || default_disk="$STORAGE_GB"
  prompt_number "Disk size for the Wolf CT rootfs (${STORAGE_GB} GB free on ${STORAGE})" \
    "$default_disk" "$STORAGE_GB" GB
  CT_DISK="$NUMBER_VALUE"
fi

# --- Wolf state volume, in GB (config, pairings, and the Steam library) ---
# A volume allocated from DLD_STORAGE by pvesm, so it works the same on lvmthin,
# LVM, ZFS, dir or NFS, and outlives the Wolf container. State cannot live on
# the CT rootfs: the daemon discards a warm rootfs whenever the image ref or
# digest changes, which would take the game library with it.
STATE_GB="${WOLF_STATE_SIZE:-}"; STATE_GB="${STATE_GB%[Gg]}"
state_max=$(( STORAGE_GB - CT_DISK )); [ "$state_max" -ge 1 ] || state_max=1
if [ -n "$STATE_GB" ]; then
  [[ "$STATE_GB" =~ ^[0-9]+$ ]] && [ "$STATE_GB" -ge 1 ] && [ "$STATE_GB" -le "$state_max" ] ||
    die "WOLF_STATE_SIZE=${WOLF_STATE_SIZE} does not fit the ${state_max} GB left on ${STORAGE} after the ${CT_DISK} GB CT rootfs."
else
  default_state=100; [ "$default_state" -le "$state_max" ] || default_state="$state_max"
  prompt_number "Size of the Wolf state volume (config, pairings, game data — ${state_max} GB available)" \
    "$default_state" "$state_max" GB
  STATE_GB="$NUMBER_VALUE"
fi

# --- CPU cores and RAM for the Wolf CT, bounded by the host ---
HOST_CPUS=$(nproc)
HOST_RAM_MB=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024 ))

CT_CPU="${WOLF_CPUS:-}"
if [ -n "$CT_CPU" ]; then
  [[ "$CT_CPU" =~ ^[0-9]+$ ]] && [ "$CT_CPU" -ge 1 ] && [ "$CT_CPU" -le "$HOST_CPUS" ] ||
    die "WOLF_CPUS=${CT_CPU} is not between 1 and the host's ${HOST_CPUS} cores."
else
  default_cpu=4; [ "$default_cpu" -le "$HOST_CPUS" ] || default_cpu="$HOST_CPUS"
  prompt_number "CPU cores for the Wolf CT (host has ${HOST_CPUS})" "$default_cpu" "$HOST_CPUS" cores
  CT_CPU="$NUMBER_VALUE"
fi

CT_RAM="${WOLF_MEMORY:-}"; CT_RAM="${CT_RAM%[Mm]}"
if [ -n "$CT_RAM" ]; then
  [[ "$CT_RAM" =~ ^[0-9]+$ ]] && [ "$CT_RAM" -ge 1 ] && [ "$CT_RAM" -le "$HOST_RAM_MB" ] ||
    die "WOLF_MEMORY=${WOLF_MEMORY} is not between 1 and the host's ${HOST_RAM_MB} MB."
else
  default_ram=4096; [ "$default_ram" -le "$HOST_RAM_MB" ] || default_ram="$HOST_RAM_MB"
  prompt_number "RAM for the Wolf CT (host has ${HOST_RAM_MB} MB)" "$default_ram" "$HOST_RAM_MB" MB
  CT_RAM="$NUMBER_VALUE"
fi

# --- GPU: one render node drives Wolf's capture/encode pipeline ---
# Probe nvidia_drm before scanning so NVIDIA render nodes appear in
# /sys/class/drm/. nvidia_drm requires modeset=1 to expose a DRM render device;
# without this, NVIDIA GPUs are invisible to the detector even when the driver
# is installed.
if command -v modprobe >/dev/null 2>&1 && command -v modinfo >/dev/null 2>&1 &&
    modinfo nvidia >/dev/null 2>&1; then
  modprobe nvidia 2>/dev/null || true
  modprobe nvidia_drm modeset=1 2>/dev/null || true
fi

GPU_RENDER_NODES=(); GPU_DRIVERS=(); GPU_VENDORS=(); gpu_labels=()
for node in /sys/class/drm/renderD*/device/driver; do
  [[ -e "$node" ]] || continue
  device_dir="$(dirname "$node")"
  render_dev="/dev/dri/$(basename "$(dirname "$device_dir")")"
  driver=$(basename "$(readlink "$node")")

  case "$driver" in
    i915|xe) vendor="Intel"  ;;
    amdgpu)  vendor="AMD"    ;;
    nvidia)  vendor="NVIDIA" ;;
    *)       vendor="Unknown ($driver)" ;;
  esac

  gpu_name="Unknown"
  pci_slot=$(basename "$(readlink -f "$device_dir")") 2>/dev/null || true
  if [[ -n "$pci_slot" ]] && command -v lspci >/dev/null 2>&1; then
    gpu_name=$(lspci -s "$pci_slot" -mm 2>/dev/null | awk -F'"' '{print $6}') || true
    [[ -z "$gpu_name" ]] && gpu_name="Unknown"
  fi

  GPU_RENDER_NODES+=("$render_dev"); GPU_DRIVERS+=("$driver"); GPU_VENDORS+=("$vendor")
  gpu_labels+=("${vendor} ${gpu_name} (${driver}, ${render_dev})")
done

[ "${#GPU_RENDER_NODES[@]}" -gt 0 ] ||
  die "No GPU render devices found in /sys/class/drm/. Are GPU drivers installed on the host?"

gpu_idx=-1
if [ -n "${WOLF_RENDER_NODE:-}" ]; then
  for i in "${!GPU_RENDER_NODES[@]}"; do
    [ "${GPU_RENDER_NODES[$i]}" = "$WOLF_RENDER_NODE" ] && { gpu_idx=$i; break; }
  done
  [ "$gpu_idx" -ge 0 ] ||
    die "Render node ${WOLF_RENDER_NODE} not found. Available: ${GPU_RENDER_NODES[*]}"
  msg_info "Using GPU: ${gpu_labels[$gpu_idx]}"
elif [ "${#GPU_RENDER_NODES[@]}" -eq 1 ]; then
  gpu_idx=0
  msg_info "Detected GPU: ${gpu_labels[0]}"
else
  prompt_choice "Select GPU for Wolf" "${gpu_labels[@]}"
  gpu_idx="$CHOICE_IDX"
  msg_info "Selected GPU: ${gpu_labels[$gpu_idx]}"
fi
RENDER_NODE="${GPU_RENDER_NODES[$gpu_idx]}"; RENDER_VENDOR="${GPU_VENDORS[$gpu_idx]}"

# --- Which build of the GOW app images to run ---
# WOLF_IMAGE_TAG pins every app image (firefox, steam, retroarch, …) and the
# pulseaudio sidecar; startup-app.sh rewrites config.toml to it on each start.
# Both flavours are published for every app image this recipe seeds.
IMAGE_TAG="${WOLF_IMAGE_TAG:-}"
if [ -n "$IMAGE_TAG" ]; then
  msg_info "App images: ${IMAGE_TAG}"
else
  image_tags=(edge fedora)
  image_labels=(
    "edge — Ubuntu-based, the tested default"
    "fedora — Fedora-based (newer Mesa; see the NVIDIA note below)"
  )
  prompt_choice "Which build of the GOW app images should Wolf run" "${image_labels[@]}"
  IMAGE_TAG="${image_tags[$CHOICE_IDX]}"
  msg_info "App images: ${IMAGE_TAG}"
fi
# startup-app.sh rejects anything else, so fail here rather than at first boot.
[[ "$IMAGE_TAG" =~ ^[A-Za-z0-9._-]+$ ]] ||
  die "WOLF_IMAGE_TAG='${IMAGE_TAG}' is not a valid image tag."

# Ask the registry whether the tag is real, rather than trusting a list here.
# A tag Wolf cannot pull surfaces as an app that just fails to launch, long
# after the installer has finished. Network trouble is not the same as a
# missing tag, so only a definite answer is fatal.
image_tag_published() { # image_tag_published <image> <tag>
  local tok
  tok=$(curl -fsSL --max-time 15 \
    "https://ghcr.io/token?scope=repository:games-on-whales/$1:pull&service=ghcr.io" 2>/dev/null |
    sed -E 's/.*"token":"([^"]+)".*/\1/') || return 2
  [ -n "$tok" ] || return 2
  curl -fsS --max-time 15 -o /dev/null -H "Authorization: Bearer $tok" \
    "https://ghcr.io/v2/games-on-whales/$1/manifests/$2" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' 2>/dev/null
}
for probe_image in steam pulseaudio; do
  # `set -e` would take a bare call's non-zero status as fatal before $? is
  # ever read — the whole point here is to inspect that status.
  probe_rc=0
  image_tag_published "$probe_image" "$IMAGE_TAG" || probe_rc=$?
  case "$probe_rc" in
    0) : ;;
    2) msg_info "Could not reach ghcr.io to confirm ${probe_image}:${IMAGE_TAG} — continuing." ;;
    *) die "ghcr.io/games-on-whales/${probe_image}:${IMAGE_TAG} does not exist. Published flavours include 'edge' and 'fedora'." ;;
  esac
done
if [ "$IMAGE_TAG" != edge ] && [ "$RENDER_VENDOR" = "NVIDIA" ]; then
  msg_info "Note: on NVIDIA, non-edge app images have been seen to fall back to llvmpipe software rendering, which Wolf's encode pipeline cannot negotiate (black screen). Switch WOLF_IMAGE_TAG back to 'edge' in ${DEST}/.env if that happens."
fi

# --- Static LAN IP + the daemon's bridge spec ---
LAN_IP="${WOLF_LAN_IP:-}"
if [ -z "$LAN_IP" ]; then
  read -rp " Static LAN IP for the Wolf CT (CIDR, e.g. 192.168.1.50/24): " LAN_IP
fi
[ -n "$LAN_IP" ] || die "A static LAN IP (CIDR) is required for Moonlight discovery."
case "$LAN_IP" in */*) : ;; *) die "LAN IP must be CIDR, e.g. 192.168.1.50/24" ;; esac

# Derive the daemon --bridge spec ('name=prefix/subnet:gateway') from the LAN IP
# and the host's default route (override wholesale with WOLF_BRIDGE).
BRIDGE_SPEC="${WOLF_BRIDGE:-}"
if [ -z "$BRIDGE_SPEC" ]; then
  ip_only="${LAN_IP%/*}"; sub="${LAN_IP#*/}"
  prefix=$(echo "$ip_only" | cut -d. -f1-3)
  gw=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
  brdev=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  brdev="${brdev:-vmbr0}"; gw="${gw:-${prefix}.1}"
  BRIDGE_SPEC="${brdev}=${prefix}/${sub}:${gw}"
fi

msg_info "Wolf on Proxmox setup"
echo "  IP:      ${LAN_IP}"
echo "  Bridge:  ${BRIDGE_SPEC}"
echo "  CPU:     ${CT_CPU} cores"
echo "  RAM:     ${CT_RAM} MB"
echo "  Disk:    ${CT_DISK} GB (CT rootfs)"
echo "  State:   ${STATE_GB} GB (/etc/wolf — config, pairings, game data)"
echo "  Storage: ${STORAGE}"
echo "  GPU:     ${gpu_labels[$gpu_idx]}"
echo "  Apps:    ${IMAGE_TAG}"
echo

# ---------- 1. docker-lxc-daemon ----------
if command -v docker-lxc-daemon >/dev/null 2>&1; then
  msg_ok "docker-lxc-daemon already installed"
else
  msg_info "Installing the latest docker-lxc-daemon"
  # `set -o pipefail` makes this whole pipeline fail when the release carries no
  # matching asset (grep exits 1) or when head closes the pipe early (SIGPIPE),
  # and a bare assignment adopts that status -- which would abort here, before
  # the check below ever runs. Let the empty result reach its own error message.
  deb_url=$(curl -fsSL "https://api.github.com/repos/${DAEMON_REPO}/releases/latest" \
    | grep -oE 'https://[^"]+_amd64\.deb' | head -1) || deb_url=""
  [ -n "$deb_url" ] || die "No .deb found in ${DAEMON_REPO} releases."
  tmp=$(mktemp --suffix=.deb); curl -fsSL "$deb_url" -o "$tmp"
  apt-get install -y "$tmp"; rm -f "$tmp"
  msg_ok "docker-lxc-daemon installed"
fi

msg_info "Configuring docker-lxc-daemon (storage=${STORAGE}, bridge=${BRIDGE_SPEC})"
mkdir -p /etc/systemd/system/docker-lxc-daemon.service.d
cat > /etc/systemd/system/docker-lxc-daemon.service.d/wolf.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/docker-lxc-daemon --pve-storage=${STORAGE} --bridge=${BRIDGE_SPEC}
EOF
systemctl daemon-reload
systemctl enable --now docker-lxc-daemon
msg_ok "docker-lxc-daemon running"

# ---------- 2. host prerequisites ----------
msg_info "Installing virtual-input + runtime prerequisites"
mkdir -p /etc/modules-load.d /etc/udev/rules.d /etc/tmpfiles.d
modprobe uinput 2>/dev/null || true
echo uinput > /etc/modules-load.d/uinput.conf
curl -fsSL "${REPO_RAW}/85-wolf-virtual-inputs.rules" -o /etc/udev/rules.d/85-wolf-virtual-inputs.rules
udevadm control --reload-rules && udevadm trigger || true
curl -fsSL "${REPO_RAW}/tmpfiles.d/wolf-proxmox.conf" -o /etc/tmpfiles.d/wolf-proxmox.conf
systemd-tmpfiles --create /etc/tmpfiles.d/wolf-proxmox.conf
msg_ok "uinput, udev rules, and tmpfiles installed"

# ensure_nvidia_cdi — make the host NVIDIA driver reachable from inside the CT.
#
# The daemon does not pass the GPU through directly: it reads the CDI spec that
# nvidia-ctk generates and translates it into LXC bind mounts, device nodes and
# a mount hook (LXC2Docker internal/lxc/nvidia.go). No nvidia-ctk means no spec,
# and the daemon then logs
#
#   buildPVEItems: NVIDIA GPU setup failed: ... "nvidia-ctk": executable file
#   not found in $PATH (container will start without GPU)
#
# to its journal and builds the CT anyway — with no driver libraries and no
# /dev/nvidia* nodes. That failure is silent where it matters, and worse than a
# clean "no GPU": /dev/dri is still bind-mounted, so Wolf finds the nvidia render
# node, logs "Using zero copy pipeline on Nvidia", and commits to the NVENC path
# before discovering it has no libcuda.so.1 and no libEGL_nvidia. eglInitialize
# then fails, the virtual compositor's setup_renderer panics, and the pipeline
# dies before its first frame. Moonlight surfaces that as "No video received
# from host", naming its own hardcoded UDP 47998/48000 — ports Wolf does not
# even use — so nothing the user sees points at the GPU.
ensure_nvidia_cdi() {
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    msg_info "Installing nvidia-container-toolkit (nvidia-ctk — GPU passthrough into the CT)"
    install -m 0755 -d /usr/share/keyrings
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    # Update only NVIDIA's list — a fresh PVE has the enterprise repo enabled
    # (401 without a subscription), which would fail a global apt-get update.
    apt-get update -qq -o Dir::Etc::sourcelist="sources.list.d/nvidia-container-toolkit.list" \
      -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"
    # -base ships nvidia-ctk without the OCI runtime hooks: the daemon consumes
    # the CDI spec itself and never invokes an NVIDIA container runtime.
    apt-get install -y nvidia-container-toolkit-base
    command -v nvidia-ctk >/dev/null 2>&1 ||
      die "nvidia-ctk still not on PATH after installing nvidia-container-toolkit-base."
    msg_ok "nvidia-container-toolkit installed"
  fi

  # Generate here rather than leaving it to the daemon's first container: a
  # failure now is on screen, where the daemon's is a journal line nobody reads.
  # Regenerating every run also clears a spec left stale by a driver upgrade,
  # which would otherwise bind libraries that no longer exist.
  msg_info "Generating the NVIDIA CDI spec"
  mkdir -p /etc/cdi
  nvidia-ctk cdi generate --format=json --output=/etc/cdi/nvidia.json >/dev/null ||
    die "nvidia-ctk cdi generate failed — is the driver loaded (nvidia-drm modeset=1)?"
  # An empty spec parses cleanly and injects nothing, reproducing the very
  # half-configured CT this function exists to prevent. Insist on device nodes.
  grep -q '"deviceNodes"' /etc/cdi/nvidia.json ||
    die "/etc/cdi/nvidia.json declares no device nodes — the CT would start without a GPU."
  msg_ok "NVIDIA CDI spec written to /etc/cdi/nvidia.json"
}

# ---------- 2b. the Wolf state volume ----------
# Wolf keeps its config, its client pairings and per-app game data (profile-data
# — Steam libraries) under /etc/wolf, which docker-compose.yml bind-mounts from
# the host. Give it a volume allocated from DLD_STORAGE and mounted there.
#
# pvesm is the storage abstraction, so this is identical on lvmthin, LVM, ZFS,
# dir and NFS: allocate, get a path, put a filesystem on it, mount. The volume
# outlives the Wolf container, which is the point: an image update discards the
# CT rootfs, so state cannot live there. WOLF_STATE_VOLUME adopts an existing
# volume id; WOLF_STATE_VMID picks the owning id.

# Bring a pvesm volume up so its path is a device that can actually be written
# to. This is the same call pct/qm make before touching a guest disk, so it
# covers every storage type and is a no-op on the file-based ones.
activate_state_volume() {
  perl -e 'use PVE::Storage; PVE::Storage::activate_volumes(PVE::Storage::config(), [$ARGV[0]]);' "$1" ||
    die "Could not activate the Wolf state volume ${1} on ${STORAGE}."
  # udev creates the device node, so it can lag the activation itself.
  if command -v udevadm >/dev/null 2>&1; then udevadm settle --timeout=10 || true; fi
}

STATE_VOLUME="${WOLF_STATE_VOLUME:-}"
if mountpoint -q /etc/wolf; then
  msg_ok "Wolf state volume already mounted at /etc/wolf"
else
  # The volume is found again by its "wolf-state" suffix, whatever id owns it.
  if [ -z "$STATE_VOLUME" ]; then
    STATE_VOLUME=$(pvesm list "$STORAGE" 2>/dev/null |
      awk '$1 ~ /wolf-state/ {print $1; exit}') || STATE_VOLUME=""
  fi

  if [ -n "$STATE_VOLUME" ]; then
    msg_info "Reusing the existing Wolf state volume ${STATE_VOLUME}"
  else
    # pvesm rejects vmid 0 ("value does not look like a valid VM ID"), so the
    # volume has to be owned by a real id. Take a high one that no guest holds,
    # well clear of the ids the daemon hands to session CTs, so that destroying
    # a guest can never take the game library with it.
    state_vmid="${WOLF_STATE_VMID:-}"
    if [ -z "$state_vmid" ]; then
      state_vmid=9000
      while [ -e "/etc/pve/qemu-server/${state_vmid}.conf" ] ||
            [ -e "/etc/pve/lxc/${state_vmid}.conf" ]; do
        state_vmid=$((state_vmid + 1))
        [ "$state_vmid" -le 9999 ] || die "No free VM ID in 9000-9999 for the Wolf state volume."
      done
    fi

    # File-based storages (dir, nfs, cifs) want an image suffix; block ones
    # (lvm, lvmthin, zfspool, rbd) take the bare name.
    case "$STORAGE_TYPE" in
      dir|nfs|cifs|glusterfs|cephfs) state_volname="vm-${state_vmid}-wolf-state.raw" ;;
      *)                            state_volname="vm-${state_vmid}-wolf-state" ;;
    esac

    msg_info "Allocating a ${STATE_GB} GB Wolf state volume on ${STORAGE} (id ${state_vmid})"
    STATE_VOLUME=$(pvesm alloc "$STORAGE" "$state_vmid" "$state_volname" "${STATE_GB}G" 2>&1 |
      awk '/successfully created/ {gsub(/'\''/, "", $NF); print $NF; exit}') || STATE_VOLUME=""
    [ -n "$STATE_VOLUME" ] || die "pvesm could not allocate ${state_volname} on ${STORAGE}."
  fi

  state_path=$(pvesm path "$STATE_VOLUME" 2>/dev/null) ||
    die "Could not resolve a path for ${STATE_VOLUME} on ${STORAGE}."
  [ -n "$state_path" ] || die "pvesm reported no path for ${STATE_VOLUME}."

  # An allocated volume is not a usable one yet. PVE leaves guest volumes
  # deactivated (PVE 9 creates LVM ones with autoactivation off), and for block
  # storages `pvesm path` is lexical — it composes /dev/<vg>/<name> without
  # looking to see whether anything is there. Without this, mkfs runs against a
  # path with no device behind it and e2fsprogs reports "The file
  # /dev/pve/vm-9000-wolf-state does not exist and no size was specified",
  # which reads like the size question was ignored but has nothing to do with it.
  activate_state_volume "$STATE_VOLUME"
  [ -e "$state_path" ] ||
    die "${STATE_VOLUME} is allocated but ${state_path} does not exist — the volume could not be activated."

  # Nothing else will ever activate this volume: it belongs to no guest, so no
  # pct start covers it, and the fstab entry below would find nothing to mount
  # at boot. 'nofail' would then let Wolf come up against an empty /etc/wolf on
  # the OS root and start collecting state there instead. Opt this one volume
  # back into boot-time autoactivation; harmless where it does not apply.
  case "$STORAGE_TYPE" in
    lvm|lvmthin) lvchange --setautoactivation y "$state_path" >/dev/null 2>&1 || true ;;
  esac

  # Format only a blank volume — a re-run must never reformat game data.
  if ! blkid -p "$state_path" >/dev/null 2>&1; then
    msg_info "Creating a filesystem on ${state_path}"
    mkfs.ext4 -q -L wolf-state "$state_path"
  fi

  mkdir -p /etc/wolf
  # Carry over anything an earlier install left on the OS root — but only onto a
  # volume that is still empty. Once Wolf owns the volume its copy is the live
  # one, and whatever remains underneath the mount point is stale: copying that
  # over the top on a re-run would roll config and pairings backwards.
  if [ -n "$(ls -A /etc/wolf 2>/dev/null)" ]; then
    state_seed=$(mktemp -d)
    mount "$state_path" "$state_seed"
    if [ -z "$(ls -A "$state_seed" 2>/dev/null)" ]; then
      cp -a /etc/wolf/. "$state_seed/"
      state_seeded=1
    else
      state_seeded=0
    fi
    umount "$state_seed" || die "Could not unmount ${state_seed} after seeding the state volume."
    # An empty temp dir left behind is harmless; never fail the install over it.
    rmdir "$state_seed" 2>/dev/null || true
    if [ "$state_seeded" = 1 ]; then
      # Empty the mount point, so this never re-runs against stale content.
      find /etc/wolf -mindepth 1 -maxdepth 1 -exec rm -rf {} +
      msg_info "Migrated the existing /etc/wolf contents onto the volume"
    else
      msg_info "The state volume already holds Wolf's data — leaving it as it is"
    fi
  fi

  mount "$state_path" /etc/wolf
  state_uuid=$(blkid -s UUID -o value "$state_path" 2>/dev/null) || state_uuid=""
  if [ -n "$state_uuid" ] && ! grep -q " /etc/wolf " /etc/fstab 2>/dev/null; then
    echo "UUID=${state_uuid} /etc/wolf ext4 defaults,nofail 0 2" >> /etc/fstab
  fi
  msg_ok "Wolf state volume ${STATE_VOLUME} mounted at /etc/wolf"
fi

# ---------- 3. recipe + .env ----------
msg_info "Fetching the Wolf recipe into ${DEST}"
mkdir -p "$DEST"
curl -fsSL "${REPO_RAW}/docker-compose.yml"        -o "${DEST}/docker-compose.yml"
curl -fsSL "${REPO_RAW}/docker-compose.nvidia.yml" -o "${DEST}/docker-compose.nvidia.yml"
[ -f "${DEST}/.env" ] || curl -fsSL "${REPO_RAW}/.env.example" -o "${DEST}/.env"

set_env() { # set_env KEY VALUE — replace the key, or append it if absent
  local key="$1" value="$2" file="${DEST}/.env"
  if grep -q "^${key}=" "$file"; then
    sed -i "s#^${key}=.*#${key}=${value}#" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}
set_env WOLF_LAN_IP      "$LAN_IP"
set_env DLD_STORAGE      "$STORAGE"
set_env WOLF_DISK_SIZE   "${CT_DISK}G"
set_env WOLF_CPUS        "$CT_CPU"
set_env WOLF_MEMORY      "${CT_RAM}M"
set_env WOLF_RENDER_NODE "$RENDER_NODE"
set_env WOLF_IMAGE_TAG   "$IMAGE_TAG"
set_env WOLF_STATE_SIZE  "${STATE_GB}G"
# Record the volume that /etc/wolf came from, so a re-run adopts exactly this
# one rather than rediscovering it — and so the uninstaller knows what it may
# free.
[ -n "${STATE_VOLUME:-}" ] && set_env WOLF_STATE_VOLUME "$STATE_VOLUME"

# The NVIDIA overlay applies only when the chosen GPU is an NVIDIA one that the
# driver actually answers for.
COMPOSE_ARGS=(-f docker-compose.yml)
if [ "$RENDER_VENDOR" = "NVIDIA" ]; then
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    COMPOSE_ARGS+=(-f docker-compose.nvidia.yml)
    msg_ok "NVIDIA GPU ${RENDER_NODE} — using the NVIDIA overlay"
    ensure_nvidia_cdi
  else
    # Falling back to the base profile here would install something that cannot
    # work: WOLF_RENDER_NODE still points at the NVIDIA node, so Wolf selects the
    # NVENC pipeline against a driver that isn't answering and dies in
    # eglInitialize on the first stream — reported to the user as a Moonlight
    # port error that never mentions the GPU. Refuse instead, and say what to fix.
    msg_err "NVIDIA GPU selected (${RENDER_NODE}) but nvidia-smi is not answering — the driver is not loaded."
    msg_info "Load it, then re-run:  modprobe nvidia_drm modeset=1   (and check 'nvidia-smi' works)"
    msg_info "To use a different GPU instead, re-run and select it at the GPU prompt."
    die "Refusing to install against an NVIDIA GPU with no working driver."
  fi
else
  msg_ok "GPU: ${RENDER_VENDOR} (${RENDER_NODE}) — using the base (Intel/AMD) profile"
fi

# ---------- 3b. Docker client (the daemon is the engine; we need the CLI) ----------
if ! docker compose version >/dev/null 2>&1; then
  msg_info "Installing the Docker CLI + compose plugin"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  codename="${VERSION_CODENAME:-bookworm}"
  # Docker's repo can lag new Debian releases; fall back to bookworm.
  curl -fsSL -o /dev/null "https://download.docker.com/linux/debian/dists/${codename}/Release" 2>/dev/null || codename=bookworm
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${codename} stable" > /etc/apt/sources.list.d/docker.list
  # Update only Docker's list — a fresh PVE has the enterprise repo enabled
  # (401 without a subscription), which would fail a global apt-get update.
  apt-get update -qq -o Dir::Etc::sourcelist="sources.list.d/docker.list" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"
  apt-get install -y docker-ce-cli docker-compose-plugin
  msg_ok "Docker CLI + compose plugin installed (client only — not the engine)"
fi

# ---------- 4. bring up ----------
msg_info "Pulling the Wolf image and starting the stack (first pull can take a while)"
cd "$DEST"
docker compose "${COMPOSE_ARGS[@]}" pull 2>/dev/null || true
docker compose "${COMPOSE_ARGS[@]}" up -d
msg_ok "Wolf is up"

ip="${LAN_IP%/*}"
echo
echo -e " ${GN}Wolf on Proxmox is ready.${CL}"
echo -e "   ${BL}Wolf Den UI:${CL}  http://${ip}:8080"
echo -e "   ${BL}Moonlight:${CL}    add host ${ip}, then enter the PIN at http://${ip}:47989"
echo -e "   ${BL}Config:${CL}       ${DEST}/.env  and  /etc/wolf/config.toml (or Wolf Den)"
echo -e "   ${BL}Remove:${CL}       bash -c \"\$(curl -fsSL ${REPO_RAW}/uninstall.sh)\""
echo
