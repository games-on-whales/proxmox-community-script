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
# Non-interactive: preset DLD_STORAGE, WOLF_LAN_IP (CIDR), and optionally
# WOLF_BRIDGE ("name=prefix/subnet:gateway") in the environment.
#
set -euo pipefail

YW=$'\033[33m'; GN=$'\033[1;92m'; RD=$'\033[01;31m'; BL=$'\033[36m'; CL=$'\033[m'
msg_info() { echo -e " ${YW}▶${CL} $*"; }
msg_ok()   { echo -e " ${GN}✓${CL} $*"; }
msg_err()  { echo -e " ${RD}✗${CL} $*" >&2; }
die()      { msg_err "$*"; exit 1; }
trap 'msg_err "install failed (line $LINENO)"' ERR

REPO_RAW="https://raw.githubusercontent.com/games-on-whales/proxmox-community-script/main"
DAEMON_REPO="games-on-whales/LXC2Docker"
DEST="${WOLF_DEST:-/opt/wolf-proxmox}"

cat <<'BANNER'
   Wolf on Proxmox — Virtual desktops & apps to Moonlight, backed by LXC2Docker
   Sessions run as sibling Proxmox CTs. https://github.com/games-on-whales/wolf
BANNER
echo

# ---------- preflight ----------
[ "$(id -u)" -eq 0 ] || die "Run as root on the Proxmox VE host."
command -v pveversion >/dev/null 2>&1 || die "Must run on a Proxmox VE host (pveversion not found)."
command -v curl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y curl; }

# ---------- 1. docker-lxc-daemon ----------
if command -v docker-lxc-daemon >/dev/null 2>&1; then
  msg_ok "docker-lxc-daemon already installed"
else
  msg_info "Installing the latest docker-lxc-daemon"
  deb_url=$(curl -fsSL "https://api.github.com/repos/${DAEMON_REPO}/releases/latest" \
    | grep -oE 'https://[^"]+_amd64\.deb' | head -1)
  [ -n "$deb_url" ] || die "No .deb found in ${DAEMON_REPO} releases."
  tmp=$(mktemp --suffix=.deb); curl -fsSL "$deb_url" -o "$tmp"
  apt-get install -y "$tmp"; rm -f "$tmp"
  msg_ok "docker-lxc-daemon installed"
fi

# ---------- gather host/network settings ----------
STORAGE="${DLD_STORAGE:-}"
if [ -z "$STORAGE" ]; then
  read -rp " Proxmox storage for containers [local-lvm]: " STORAGE
  STORAGE="${STORAGE:-local-lvm}"
fi

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

# ---------- 3. recipe + .env ----------
msg_info "Fetching the Wolf recipe into ${DEST}"
mkdir -p "$DEST"
curl -fsSL "${REPO_RAW}/docker-compose.yml"        -o "${DEST}/docker-compose.yml"
curl -fsSL "${REPO_RAW}/docker-compose.nvidia.yml" -o "${DEST}/docker-compose.nvidia.yml"
[ -f "${DEST}/.env" ] || curl -fsSL "${REPO_RAW}/.env.example" -o "${DEST}/.env"
sed -i "s#^WOLF_LAN_IP=.*#WOLF_LAN_IP=${LAN_IP}#" "${DEST}/.env"
sed -i "s#^DLD_STORAGE=.*#DLD_STORAGE=${STORAGE}#" "${DEST}/.env"

# GPU / render-node autodetect
COMPOSE_ARGS=(-f docker-compose.yml)
gpu="none"; nvidia_node=""
for d in /sys/class/drm/renderD*; do
  [ -e "$d/device/driver" ] || continue
  drv=$(basename "$(readlink -f "$d/device/driver")")
  node="/dev/dri/$(basename "$d")"
  case "$drv" in
    nvidia) nvidia_node="$node"; gpu="nvidia" ;;
    i915|xe|amdgpu) [ "$gpu" = "none" ] && gpu="$drv" ;;
  esac
done
if [ -n "$nvidia_node" ] && command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  COMPOSE_ARGS+=(-f docker-compose.nvidia.yml)
  sed -i "s#^WOLF_RENDER_NODE=.*#WOLF_RENDER_NODE=${nvidia_node}#" "${DEST}/.env"
  msg_ok "NVIDIA GPU detected (${nvidia_node}) — using the NVIDIA overlay"
elif [ -n "$nvidia_node" ]; then
  msg_err "NVIDIA GPU found at ${nvidia_node} but nvidia-smi failed — driver not loaded (nvidia-drm modeset=1)?"
  msg_info "Using the base profile for now (no GPU encode). Load the driver and re-run for hardware acceleration."
else
  msg_ok "GPU: ${gpu} — using the base (Intel/AMD) profile"
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
  apt-get update -qq
  apt-get install -y docker-ce-cli docker-compose-plugin
  msg_ok "Docker CLI + compose plugin installed (client only � not the engine)"
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
echo
