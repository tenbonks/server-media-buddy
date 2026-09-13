# Media Server Setup — Beelink / Ubuntu Server

Personal reference for the Jellyfin + Komga media server build and the planned upgrade path.

**Server:** Beelink, Intel CPU (QuickSync), Ubuntu Server 24.04 LTS
**Server IP:** `192.168.0.33`
**SSH user:** `tbonks`  ·  **Hostname:** `tbmediaserver`
**Domain:** `jellyfin.web-sights.co.uk` (via Cloudflare tunnel + Access OTP)
**Services:** Jellyfin (film/TV) · Komga (comics) — both behind the same Cloudflare tunnel
**Media drive (current):** WD Elements 4TB, NTFS, mounted at `/mnt/media`

---

## Table of contents

1. [Architecture overview](#1-architecture-overview)
2. [Phase 1 — CURRENT: Jellyfin + Komga + tunnel (done)](#2-phase-1--current-jellyfin--komga--tunnel)
3. [Everyday use: adding content (manual torrent + rsync)](#3-everyday-use--adding-content-manual-torrent--rsync)
4. [Bringing the stack down / up (unmounting the media drive)](#4-bringing-the-stack-down--up-unmounting-the-media-drive)
5. [Phase 2 — PLANNED: new ext4 drive migration](#5-phase-2--planned-new-ext4-drive-migration)
6. [Phase 3 — PLANNED: full arr automation stack](#6-phase-3--planned-full-arr-automation-stack)
7. [Reference — paths, ports, useful commands](#7-reference)

---

## 1. Architecture overview

```
                 Internet
                    │
          Cloudflare (Access OTP gate)
                    │  tunnel (no open ports on home network)
                    ▼
   ┌─────────────────────────────────────────┐
   │  Beelink — Ubuntu Server (192.168.0.33)  │
   │                                          │
   │   Docker:                                │
   │     cloudflared ─┬ http://jellyfin:8096  │
   │                  └ http://komga:25600    │
   │     jellyfin  (QuickSync transcoding)    │
   │     komga     (comics reader)            │
   │                                          │
   │     [Phase 3 additions:]                 │
   │     gluetun (Proton WireGuard + killswitch)
   │     qbittorrent (routed via gluetun)     │
   │     prowlarr / sonarr / radarr           │
   │                                          │
   │   /mnt/media  ← media drive              │
   └─────────────────────────────────────────┘
```

**Security model:** Nothing on the Beelink is exposed directly to the internet.
The only inbound path is the Cloudflare tunnel, gated by the email-OTP Access
policy. Jellyfin's own UPnP / automatic port mapping stays **OFF**.

---

## 2. Phase 1 — CURRENT: Jellyfin + Komga + tunnel

### 2.1 Ubuntu Server install (done)

**Summary of choices:** Ubuntu Server 24.04 LTS (full, not minimized) · OpenSSH
server enabled during install · HWE kernel (default — good for newer Intel iGPU /
QuickSync support) · static IP via router DHCP reservation → `192.168.0.33`.

**a. Create the install USB (balenaEtcher)**

Done from another PC (Windows/Mac), with an 8 GB+ USB stick (flashing **wipes**
it).

1. Download the **Ubuntu Server 24.04 LTS** ISO from
   <https://ubuntu.com/download/server> (the manual/"Option 2" ISO download).
2. Download and install **balenaEtcher** from <https://etcher.balena.io/>.
3. In Etcher: **Flash from file** → pick the ISO → **Select target** → pick the
   USB stick (double-check it's the right device) → **Flash!**
4. When it finishes and validates, eject the USB.

**b. Boot the Beelink from the USB**

1. ⚠️ **Unplug the WD Elements media drive first**, so it can't be picked as the
   install target by mistake. Only the internal disk should be connected during
   install.
2. Plug the USB into the Beelink, power on, and spam the boot-menu key at the
   splash — on Beelink mini PCs this is usually **F7** (one-time boot menu);
   **DEL** or **ESC** enters full BIOS setup. Models vary, so watch the splash
   text.
3. Choose the USB stick from the boot menu. If it won't boot, enter BIOS and
   confirm the USB is above the internal disk in boot order (Secure Boot can stay
   on — Ubuntu supports it).

**c. Run the Ubuntu Server installer**

1. Language → keyboard layout.
2. Choose **Ubuntu Server** (full), not the minimized variant.
3. Network: leave on DHCP for now (the fixed `192.168.0.33` is a **router DHCP
   reservation** set later, not a static config on the box). Note the MAC/current
   IP so you can find it to SSH in.
4. Proxy: blank. Mirror: default.
5. **Storage: guided, use an entire disk** — select the **internal** disk (eMMC/
   SSD). Confirm the summary shows only the internal disk being formatted, never
   the media drive.
6. Profile: your name, server name **`tbmediaserver`**, username **`tbonks`**,
   password.
7. **☑ Install OpenSSH server** (import keys optional). Skip the featured snaps.
8. Let it install, then **reboot and remove the USB** when prompted.

**d. First login + reservation**

1. SSH in from another machine: `ssh tbonks@<current-ip>`.
2. In the **router admin**, add a **DHCP reservation** binding the Beelink's MAC
   to `192.168.0.33` so the address never changes. Reboot the Beelink; from here
   on it's reachable at `ssh tbonks@192.168.0.33`.
3. Update the box: `sudo apt update && sudo apt full-upgrade -y`.
4. Reconnect the WD Elements media drive (mounting it comes next, 2.2).

### 2.2 Mount the media drive (NTFS)

```bash
sudo apt update && sudo apt install ntfs-3g -y
sudo mkdir -p /mnt/media
```

Add to `/etc/fstab` (`sudo nano /etc/fstab`):

```
UUID=C8DA9665DA964F94  /mnt/media  ntfs-3g  defaults,uid=1000,gid=1000,umask=022,nofail  0  0
```

- `nofail` = missing USB drive won't block a headless boot.
- Mount + verify:

```bash
sudo mount -a
ls /mnt/media          # should show the Media folder
```

**Existing library structure on the drive:**
```
/mnt/media/Media/Films     ← movies
/mnt/media/Media/TV        ← TV shows
/mnt/media/Media/Comics    ← comics (served by Komga, not Jellyfin)
```
(Case matters — Media / Films / TV / Comics are capitalised.)

Downloads folder (sibling to Media, ready for Phase 3):
```bash
mkdir -p /mnt/media/downloads
```

### 2.3 Install Docker

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker
docker run hello-world      # test
```

### 2.4 GPU access for QuickSync

```bash
sudo usermod -aG render $USER
sudo usermod -aG video $USER
newgrp render
ls -l /dev/dri              # expect card0 + renderD128
```

### 2.5 Docker Compose — Jellyfin + cloudflared

Folder:
```bash
mkdir -p ~/media-stack/config/{jellyfin,komga}
cd ~/media-stack
```

`~/media-stack/docker-compose.yml`:

```yaml
services:
  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: jellyfin
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/London
    volumes:
      - ./config/jellyfin:/config
      - /mnt/media/Media:/data/media
    ports:
      - 8096:8096
    devices:
      - /dev/dri:/dev/dri
    restart: unless-stopped

  komga:
    image: lscr.io/linuxserver/komga:latest
    container_name: komga
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/London
    volumes:
      - ./config/komga:/config
      - /mnt/media/Media/Comics:/data
    ports:
      - 25600:25600
    restart: unless-stopped

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    command: tunnel --no-autoupdate run --token YOUR_TOKEN_HERE
    restart: unless-stopped
```

Launch:
```bash
docker compose up -d
docker logs jellyfin
docker logs cloudflared
```

### 2.6 Jellyfin first-run (browser → http://192.168.0.33:8096)

- Create admin user + password.
- Add libraries pointing at **container** paths:
  - Movies → `/data/media/Films`
  - Shows  → `/data/media/TV`
  - (Comics are **not** a Jellyfin library any more — Komga handles them, see 2.9.)
- "Allow remote connections to this server" → **ON** (needed for the tunnel).
- UPnP / automatic port mapping → **OFF**.

### 2.7 Hardware transcoding

Dashboard → Playback → Transcoding:
- Hardware acceleration: **Intel QuickSync (QSV)**
- Enable H264 + HEVC decoding.
- Save.

### 2.8 Cloudflare tunnel (dashboard-managed)

Tunnel name: **BENFLIX-PRIME-PLUS** · Tunnel ID: `30e35c16-f18c-43f0-b120-0b7cd34e36e3`

- Runs as the `cloudflared` container above (token from the tunnel's
  "Install cloudflared connector" → Docker command → the `--token eyJ...` value).
- **Route service URL:** `http://jellyfin:8096`
  (container name, NOT localhost — cloudflared reaches Jellyfin over the shared
  Docker network by service name.)
- Access policy **"Jellyfin Access"** (email OTP) is attached to the
  application/hostname, so it persists across connector/server changes.
- Dashboard should show **Healthy** / 1 active replica once the container runs.
- **Komga shares this same tunnel/connector** — see 2.9. No second tunnel; the
  one cloudflared container fronts both Jellyfin and Komga over the shared Docker
  network.

### 2.9 Komga first-run (comics)

Komga replaces the old Jellyfin "Books" library for comics.

- Browse to `http://192.168.0.33:25600` on the LAN — the first visit creates the
  admin account (email + password).
- Add a library pointing at the **container** path `/data`
  (mapped to `/mnt/media/Media/Comics`). Name it e.g. "Comics".
- Reads `.cbz` / `.cbr` / PDF. It matches on folder + file names; add a ComicVine
  API key (Settings) if you want richer series/issue metadata.
- **Exposed through the same BENFLIX-PRIME-PLUS Cloudflare tunnel as Jellyfin**
  (2.8) — cloudflared reaches it over the shared Docker network as
  `http://komga:25600`, behind the same "Jellyfin Access" OTP policy. UPnP stays
  off; no ports opened at home.
  *(TODO: confirm the exact public hostname / route used for Komga in the
  Cloudflare dashboard and note it here.)*

---

## 3. Everyday use — adding content (manual torrent + rsync)

Until the arr stack is live (Phase 3), acquire media on another PC and copy over.

> **Helper tool:** the `server-media-buddy` repo (`upload-films.sh` /
> `upload-tv.sh`) wraps the rsync commands below with the right flags and
> destinations — use those day-to-day. The raw commands here are the
> fallback/reference. See that repo's README.

- Torrent on the desktop PC with Proton VPN running (P2P server).
- Transfer into the correct library folder:

```bash
# movie
rsync -avP "/path/to/Movie.mkv" tbonks@192.168.0.33:/mnt/media/Media/Films/

# tv (into a show folder)
rsync -avP "/path/to/Show.S01E01.mkv" tbonks@192.168.0.33:/mnt/media/Media/TV/ShowName/
```

`-avP` = archive + verbose + progress/resume.

Files land in the same folders the arr stack will later manage, so nothing is
wasted when automation is added. Name files sensibly (`Show - S01E02.mkv`) so
Jellyfin matches metadata.

---

## 4. Bringing the stack down / up (unmounting the media drive)

The containers hold `/mnt/media` open, so the stack must be stopped before the
drive can be unmounted — e.g. to unplug/swap it, run a filesystem check, or for
the Phase 2 ext4 migration.

Helper **bash scripts + shell aliases** for this live on the server in
`~/media-stack/` (set up in an earlier session) so it's a one-liner from
anywhere.

> **TODO:** paste the exact script filenames, alias definitions, and their
> contents here once pulled off the server.

The raw flow they wrap:

```bash
cd ~/media-stack
docker compose down            # release /mnt/media (stops jellyfin + komga)
sudo umount /mnt/media         # now safe to unplug / fsck / swap the drive
# ... work on the drive ...
sudo mount -a                  # remount per /etc/fstab
docker compose up -d           # bring the stack back up
```

If `umount` reports the target is busy, something is still holding the mount —
check with `sudo lsof +f -- /mnt/media` (or `fuser -vm /mnt/media`) and make sure
`docker compose down` actually stopped every container.

---

## 5. Phase 2 — PLANNED: new ext4 drive migration

**Goal:** replace the NTFS Elements drive with a new drive formatted **ext4**, so
hardlinks work (instant, space-free imports in Phase 3).

**Why:** NTFS on Linux can't do reliable hardlinks → the arr stack would *copy*
instead of link (double disk use, slower). ext4 fixes this.

### Steps (when the new drive arrives)

1. Connect the new drive. Identify it:
   ```bash
   lsblk -f
   sudo blkid
   ```
2. Partition + format ext4 (⚠️ wipes the target drive — triple-check the device):
   ```bash
   sudo parted /dev/sdX --script mklabel gpt
   sudo parted /dev/sdX --script mkpart primary ext4 0% 100%
   sudo mkfs.ext4 -L media /dev/sdX1
   ```
3. Temp-mount and copy media across from the old drive:
   ```bash
   sudo mkdir -p /mnt/newdrive
   sudo mount /dev/sdX1 /mnt/newdrive
   sudo rsync -avP /mnt/media/Media/ /mnt/newdrive/Media/
   ```
4. Verify the copy, then swap mounts:
   - Get new drive UUID (`sudo blkid`).
   - Edit `/etc/fstab`: replace the NTFS line with the new ext4 UUID mounting at
     `/mnt/media`. ext4 doesn't need uid/gid/umask options:
     ```
     UUID=<new-ext4-uuid>  /mnt/media  ext4  defaults,nofail  0  2
     ```
   - Unmount old, remount:
     ```bash
     sudo umount /mnt/media       # old NTFS (adjust if mounted elsewhere)
     sudo mount -a
     ls /mnt/media/Media
     ```
5. Fix ownership so containers can write:
   ```bash
   sudo chown -R 1000:1000 /mnt/media
   ```
6. Recreate downloads folder:
   ```bash
   mkdir -p /mnt/media/downloads
   ```
7. Jellyfin paths are unchanged (`/mnt/media/Media/...`) — nothing to reconfigure.
8. Old Elements drive → keep as backup or repurpose.

---

## 6. Phase 3 — PLANNED: full arr automation stack

**Adds:** gluetun (Proton VPN + killswitch), qBittorrent, Prowlarr, Sonarr, Radarr.
**Requires:** Phase 2 done (ext4) for proper hardlinking.

### 5.1 Proton WireGuard config

- Proton dashboard → WireGuard → generate config for a **P2P server**.
- Note `PrivateKey` and the `Address =` value.

### 5.2 `.env` (in `~/media-stack/`)

```
PUID=1000
PGID=1000
TZ=Europe/London
WG_PRIVATE_KEY=your_proton_wireguard_private_key
WG_ADDRESSES=10.2.0.2/32
SERVER_COUNTRIES=Netherlands
```

### 5.3 Add these services to `docker-compose.yml`

```yaml
  gluetun:
    image: qmcgaw/gluetun:latest
    container_name: gluetun
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - 8080:8080          # qBittorrent web UI (via gluetun)
      - 6881:6881
      - 6881:6881/udp
    volumes:
      - ./config/gluetun:/gluetun
    environment:
      - VPN_SERVICE_PROVIDER=protonvpn
      - VPN_TYPE=wireguard
      - WIREGUARD_PRIVATE_KEY=${WG_PRIVATE_KEY}
      - WIREGUARD_ADDRESSES=${WG_ADDRESSES}
      - SERVER_COUNTRIES=${SERVER_COUNTRIES}
      - VPN_PORT_FORWARDING=on
      - VPN_PORT_FORWARDING_PROVIDER=protonvpn
      - TZ=${TZ}
    restart: unless-stopped

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    network_mode: "service:gluetun"      # ALL traffic through the VPN
    depends_on:
      - gluetun
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - WEBUI_PORT=8080
    volumes:
      - ./config/qbittorrent:/config
      - /mnt/media:/data
    restart: unless-stopped

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ./config/prowlarr:/config
    ports:
      - 9696:9696
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ./config/sonarr:/config
      - /mnt/media:/data
    ports:
      - 8989:8989
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ./config/radarr:/config
      - /mnt/media:/data
    ports:
      - 7878:7878
    restart: unless-stopped
```

Create config dirs first:
```bash
mkdir -p ~/media-stack/config/{gluetun,qbittorrent,prowlarr,sonarr,radarr}
docker compose up -d
```

### 5.4 VERIFY THE VPN BEFORE ADDING ANY TORRENTS

```bash
docker exec gluetun wget -qO- https://ipinfo.io/ip      # Proton IP
docker exec qbittorrent wget -qO- https://ipinfo.io/ip  # MUST match gluetun, NOT home IP
```
If qBittorrent shows your real IP → stop, killswitch isn't working.

### 5.5 App configuration order

1. **qBittorrent** (`http://192.168.0.33:8080`) — temp password from
   `docker logs qbittorrent`; change it. Default save path → `/data/downloads`.
   - **Seeding:** Options → BitTorrent → set ratio limit `0` and/or seeding time
     `0`, action **"Stop torrent"**. → stops uploading the moment a download
     finishes.
   - Cap upload speed low but **not zero** (zero can stall downloads).
2. **Prowlarr** (`:9696`) — add torrent indexers; Settings → Apps → connect
   Sonarr + Radarr (indexers auto-push to both).
3. **Sonarr** (`:8989`) / **Radarr** (`:7878`):
   - Root folder: `/data/Media/TV` (Sonarr) · `/data/Media/Films` (Radarr).
   - Download client: qBittorrent, host `gluetun`, port `8080`.
   - Enable "remove completed downloads after import" so duplicates don't linger.
4. **Jellyfin** — already reading `/data/media/...`; new files just appear.

### 5.6 Path mapping recap (Phase 3)

| On the drive              | In containers        | Used by                  |
|---------------------------|----------------------|--------------------------|
| `/mnt/media`              | `/data`              | qbittorrent, sonarr, radarr |
| `/mnt/media/downloads`    | `/data/downloads`    | torrents land here       |
| `/mnt/media/Media/TV`     | `/data/Media/TV`     | Sonarr library           |
| `/mnt/media/Media/Films`  | `/data/Media/Films`  | Radarr library           |
| `/mnt/media/Media`        | `/data/media`        | Jellyfin (reads all)     |

Single `/mnt/media → /data` root = hardlinks work (on ext4). One shared root is
the whole trick.

---

## 7. Reference

### Ports (LAN-only unless noted)
| Service      | Port | Notes                                   |
|--------------|------|-----------------------------------------|
| Jellyfin     | 8096 | exposed externally via Cloudflare tunnel |
| Komga        | 25600| exposed externally via the same Cloudflare tunnel |
| qBittorrent  | 8080 | via gluetun (Phase 3)                   |
| Prowlarr     | 9696 | Phase 3                                 |
| Sonarr       | 8989 | Phase 3                                 |
| Radarr       | 7878 | Phase 3                                 |

**Keep everything except Jellyfin and Komga LAN-only. Never route the arr apps
or qBittorrent through the Cloudflare tunnel.**

### Useful commands
```bash
cd ~/media-stack

docker compose up -d           # start / apply changes
docker compose down            # stop all
docker compose pull            # update images
docker compose up -d           # re-create with new images
docker logs -f jellyfin        # follow a container's logs
docker ps                      # list running containers
df -h /mnt/media               # disk space
lsblk -f                       # drives + filesystems + UUIDs
```

### Key facts
- SSH: `ssh tbonks@192.168.0.33`
- Compose lives in `~/media-stack/`, configs under `~/media-stack/config/`.
- Comics are served by **Komga** (`:25600`), which replaced the old Jellyfin
  "Books" library. Same Cloudflare tunnel + OTP as Jellyfin.
- Stack down/up helper scripts + aliases live in `~/media-stack/` (see §4) —
  stop the stack before unmounting `/mnt/media`.
- UID/GID `1000:1000` throughout.
- NTFS now → ext4 after Phase 2 (hardlinks). NTFS copies instead of links but
  does **not** error.
- Cloudflare Access "Jellyfin Access" OTP policy is on the hostname — survives
  server/connector changes.
