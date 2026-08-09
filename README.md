# Wolf on Proxmox (LXC2Docker)

Run [Games-on-Whales Wolf](https://github.com/games-on-whales/wolf) — stream
virtual desktops and applications to Moonlight clients — on a Proxmox VE host,
backed by [`docker-lxc-daemon`](https://github.com/games-on-whales/LXC2Docker).
This is the Proxmox counterpart of the SmoothNAS Wolf plugin: the same container
shape, expressed as a Compose file against the host daemon, with the Wolf Den
management UI bundled on `:8080`.

## Quick install (Proxmox host)

Run on your Proxmox VE node:

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/games-on-whales/proxmox-community-script/main/install.sh)"
```

It installs `docker-lxc-daemon`, the virtual-input/runtime prerequisites, and
Wolf. Everything is asked up front — the same selection model as the Wolf
[quickstart scripts](https://github.com/games-on-whales/wolf/tree/main/quickstart)
this installer descends from: a numbered list of what the host actually has,
defaulting to the first entry, auto-selected when there is only one candidate.

| Prompt | Candidates / bound | Default |
| --- | --- | --- |
| Storage for the Wolf CT | active `rootdir` storages, with free space (`pvesm status`) | first listed |
| Disk size in GB (game data) | free space on the chosen storage | `100` |
| CPU cores | `nproc` | `4` |
| RAM in MB | `MemTotal` | `4096` |
| GPU | render nodes under `/sys/class/drm/`, as `vendor name (driver, node)` | first listed |
| Static LAN IP (CIDR) | must be CIDR | — |

`nvidia_drm modeset=1` is probed before the GPU scan, since NVIDIA cards expose
no render node without it. The bridge spec is derived from the LAN IP and the
host's default route. To run unattended, preset `DLD_STORAGE`, `WOLF_LAN_IP`,
`WOLF_DISK_SIZE`, `WOLF_CPUS`, `WOLF_MEMORY`, `WOLF_RENDER_NODE` (and optionally
`WOLF_BRIDGE`) — anything left unset takes its default, and a preset that isn't
a real candidate, or doesn't fit the host, aborts the install. The manual steps
below are the equivalent, broken out.

`bash tests/gather-dryrun.sh` exercises this section against a faked host.

## How it works

`docker-lxc-daemon` on the PVE host serves the Docker Engine API but backs every
container with an LXC / Proxmox CT. Wolf runs as one such CT with the host socket
bind-mounted in, so each session it starts (a desktop, an app, or a game) is
launched as a **sibling Proxmox CT** through the same daemon — not a nested
container.

The Compose file reproduces the SmoothNAS `wolf-runtime` + `gpu-*` profiles:

| SmoothNAS plugin | Here (Compose → LXC2Docker) |
| --- | --- |
| `wolf-runtime` socket mount | `-v /var/run/docker.sock:/var/run/docker.sock` |
| `wolf-runtime` devices/caps | `devices:` + `cap_add:` + `device_cgroup_rules:` |
| `gpu-nvidia` profile | `docker-compose.nvidia.yml` (`NVIDIA_VISIBLE_DEVICES` → CDI) |
| `gpu-intel` / `gpu-amd` | base file (`/dev/dri`) |
| tier-bound `state` volume | `-v /etc/wolf:/etc/wolf` |
| identity-mapped runtime vol | `-v ${WOLF_RUNTIME_DIR}:${WOLF_RUNTIME_DIR}` |
| bundled Wolf Den (`:8080`) | `Dockerfile` (Wolf + Wolf Den wrapper entrypoint) |
| `hostExpose` Moonlight ports | `gow.lan` static IP on the CT |
| SmoothNAS LXC runtime | `docker-lxc-daemon` on the PVE host |
| _(new for Proxmox)_ | `gow.pve=true` → sessions are Proxmox CTs |

## Prerequisites

1. **docker-lxc-daemon on the PVE host**:
   ```sh
   bash -c "$(curl -fsSL https://raw.githubusercontent.com/games-on-whales/LXC2Docker/main/scripts/install-on-pve.sh)"
   systemctl enable --now docker-lxc-daemon
   ```
   Configure its `--lan-*` bridge so CTs can take a static LAN IP.
2. **GPU drivers loaded on the host** (Intel/AMD `/dev/dri`, or NVIDIA with
   `nvidia-drm modeset=1`). Confirm with `ls /dev/dri` / `nvidia-smi`.
3. **NVIDIA only — `nvidia-container-toolkit` on the host**, for `nvidia-ctk`:
   ```sh
   curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
     | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
   curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
     | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
     > /etc/apt/sources.list.d/nvidia-container-toolkit.list
   apt-get update && apt-get install -y nvidia-container-toolkit-base
   nvidia-ctk cdi generate --format=json --output=/etc/cdi/nvidia.json
   ```
   The daemon injects the host driver into the CT by translating this CDI spec
   into LXC mounts and device nodes — it does not pass the GPU through directly.
   Without `nvidia-ctk` it logs `NVIDIA GPU setup failed ... (container will
   start without GPU)` to its journal and builds the CT with **no driver
   libraries and no `/dev/nvidia*`**, while `/dev/dri` still gets passed through.
   Wolf then finds the NVIDIA render node, commits to the NVENC pipeline, and
   panics in `eglInitialize` on the first stream. Moonlight reports that as
   *"No video received from host"* naming UDP 47998/48000 — ports Wolf never
   uses — so nothing on screen points at the GPU. The installer does all of this
   for you and refuses to continue if it can't.
4. **Virtual-input udev rules** on the host:
   ```sh
   install -m 0644 85-wolf-virtual-inputs.rules /etc/udev/rules.d/
   modprobe uinput
   udevadm control --reload-rules && udevadm trigger
   ```
5. **A free static LAN IP** for the Wolf CT (Moonlight discovery relies on
   mDNS/multicast reaching the LAN).
6. **Bind-mount source dirs on the host** — Wolf's `/etc/wolf` (state) and
   `/run/wolf` (runtime) are bind-mounted from the host, so they must exist
   before it starts (`/run` is tmpfs, so recreate `/run/wolf` on boot):
   ```sh
   install -m 0644 tmpfiles.d/wolf-proxmox.conf /etc/tmpfiles.d/
   systemd-tmpfiles --create /etc/tmpfiles.d/wolf-proxmox.conf
   ```

## Bring up

```sh
cp .env.example .env      # set WOLF_LAN_IP, DLD_STORAGE, WOLF_RENDER_NODE, ...
# The image is published by the CI workflow; pull it (or `docker compose build`).
docker compose up -d                                             # Intel / AMD
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml up -d   # NVIDIA
```

- **Wolf Den UI:** `http://<WOLF_LAN_IP>:8080`
- **Pairing:** point Moonlight at `<WOLF_LAN_IP>`, then open
  `http://<WOLF_LAN_IP>:47989` to enter the PIN and pick a desktop/app.

## Ports (Moonlight)

`47984/tcp` `47989/tcp` `47999/udp` `48010/tcp` `48100/udp` `48200/udp` (+ Wolf
Den `8080/tcp`). With the `gow.lan` static IP these are reachable directly on the
CT. On segmented LANs you may need a multicast querier on the bridge for
discovery.

## Publishing the image

`docker compose build` builds locally. To publish a shared
`ghcr.io/games-on-whales/wolf-proxmox` image, run the
`.github/workflows/wolf-proxmox-image.yml` workflow (manual dispatch), then set
`WOLF_IMAGE` to the pinned tag/digest.

## Configuration

On first start the bundled `startup-app.sh` seeds `/etc/wolf/config.toml` with a
fresh host uuid and the default app profile set (`config/default-config.toml` —
Wolf UI, desktops, Steam, RetroArch, …), pins the GOW app images to
`WOLF_IMAGE_TAG` (default `edge` — the versioned tags such as `steam:fedora-43`
can fall back to llvmpipe software rendering, which Wolf's NVIDIA encode
pipeline fails to negotiate, yielding a black screen), and installs `fake-udev`. Edit `/etc/wolf/config.toml`
afterwards (or use Wolf Den) to customise apps; it is preserved across restarts.

**Game data / disk space:** Wolf stores its state, its client pairings and
per-app game data (Steam libraries) under `/etc/wolf`. The installer backs that
with a **volume allocated from `DLD_STORAGE` by `pvesm`**, so it behaves the same
on lvmthin, LVM, ZFS, dir or NFS — no host filesystem layout to arrange, and
nothing on the OS root. Size it with `WOLF_STATE_SIZE` (GB, prompted at install
time, default 200); set `WOLF_STATE_VOLUME` to adopt an existing volume id.

The volume is owned by no guest (`vmid 0`) and lives outside the Wolf container
on purpose: the daemon discards a warm CT rootfs whenever the image ref or
digest changes, so state kept on the rootfs would be destroyed by a routine
image update. Re-running the installer reuses the volume and never reformats it.

**CT sizing:** `WOLF_DISK_SIZE` sizes the Wolf CT's rootfs on `DLD_STORAGE`, and
`WOLF_CPUS` / `WOLF_MEMORY` cap its cores and RAM. Leave the latter two unset
and the CT is uncapped — all host cores and RAM, the daemon's default. Session
CTs that Wolf launches are sized separately, by Wolf.

## Controllers

Wolf builds virtual gamepads on the host via `uinput` and injects them into each
session, so controllers work in the Wolf UI, Steam Big Picture, and games.

**Known caveat — Steam Input:** for games launched through Steam with *Steam
Input* enabled, the controller may not register in-game. Steam Input grabs the
physical pad and builds its own virtual gamepad via `/dev/uinput` *inside the
session container*, which isn't passed through to sessions yet (only Wolf itself
gets `uinput`). Until that lands, **disable Steam Input** so the game reads
Wolf's pad directly:

- Per game: *game → ⚙ → Controller → Override for … → Disable Steam Input*, or
- Globally: *Steam → Settings → Controller → turn off the desktop/BPM toggles*.

Menus (Wolf UI, Big Picture) are unaffected — they read the pad over evdev.

## Status

Verified on a live Proxmox VE host (RTX 5080): Wolf + Wolf Den, sibling session
CTs, controllers, and hardware NVENC all working. Mirrors the production
SmoothNAS Wolf plugin.
