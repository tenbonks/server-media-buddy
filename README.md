# server-media-buddy

Helper scripts for managing my **Jellyfin + Komga** media server — the tooling
side of the setup documented in [`media-server-setup.md`](media-server-setup.md).

Right now it does one job well: **rsync films, TV shows, and comics** from a
local machine into the server's media libraries. More content-management helpers
will land here as the server grows.

## The media server (quick context)

- **Beelink / Ubuntu Server 24.04**, running **Jellyfin** (film/TV) and **Komga**
  (comics), both behind a Cloudflare tunnel with Access OTP. Full build + roadmap
  in [`media-server-setup.md`](media-server-setup.md).
- **Media drive:** WD Elements 4TB, **NTFS**, mounted at `/mnt/media`
  (ext4 migration is planned — Phase 2).
- Content is currently added **manually** (torrent on another PC → rsync over)
  until the arr automation stack lands (Phase 3). These scripts *are* that manual
  step.

## Files

- `config.sh` — shared settings (server address, destination + default source folders). **Git-ignored** — copy it from `config-example.sh` and edit.
- `config-example.sh` — template for `config.sh` (safe to commit).
- `upload-films.sh` — upload films to the server's Films library (Jellyfin).
- `upload-tv.sh` — upload TV shows to the server's TV library (Jellyfin).
- `upload-comics.sh` — upload comics to the server's Comics library (Komga).

## Setup

1. Create your config from the template and edit it:
   ```bash
   cp config-example.sh config.sh
   # edit config.sh with your server address and paths
   ```
2. Make the scripts executable:
   ```bash
   chmod +x upload-films.sh upload-tv.sh upload-comics.sh config.sh
   ```
3. (Recommended) Set up SSH key auth so you're not prompted for a password each time:
   ```bash
   ssh-copy-id tbonks@192.168.0.33
   ```

## Usage

Use the default source folder (set in `config.sh`):
```bash
./upload-films.sh
./upload-tv.sh
./upload-comics.sh
```

Or pass a specific folder to upload the contents of:
```bash
./upload-films.sh "/path/to/some/films/"
./upload-tv.sh "/path/to/some/tv/"
./upload-comics.sh "/path/to/some/comics/"
```

## Notes

- The scripts add a trailing slash to the source automatically, so the
  **contents** of the source folder land in the destination (not nested inside
  another folder).
- `rsync -avP` gives archive mode, progress, and resume — if a transfer drops,
  just run the same command again and it picks up where it left off.
- `--no-perms --no-owner --no-group` are set because the server drive is
  currently **NTFS**, where preserving Linux permissions is pointless and noisy.
  Remove these flags once the drive is **ext4** (Phase 2) if you want
  ownership/permissions preserved.
- Make sure the media drive is mounted and the stack is running on the server
  before uploading.
- After uploading, trigger a library scan in Jellyfin (or wait for the scheduled
  one) to pull new media in with metadata. Komga picks up new comics on its own
  scan.

## Bringing the stack down / up (unmounting the media drive)

When you need to unmount or swap the media drive, the containers holding
`/mnt/media` open must be stopped first. Helper **bash scripts + aliases** for
this live **on the server** in `~/media-stack/` (defined in an earlier setup
session), and the flow is documented in
[`media-server-setup.md` §4](media-server-setup.md).

> **TODO:** once the exact script names/aliases are pulled off the server, record
> them here (and in `media-server-setup.md`) — or move copies of the scripts into
> this repo.

The raw flow they wrap:
```bash
cd ~/media-stack
docker compose down          # release /mnt/media
sudo umount /mnt/media
# ... swap / check the drive ...
sudo mount -a
docker compose up -d
```

## File naming

For best metadata matching:

- **Films (Jellyfin):** `Title (Year) [imdbid-ttXXXXXXX]/Title (Year).mkv`
- **TV (Jellyfin):** `Show Name/Season 01/Show Name - S01E01.mkv`
- **Comics (Komga):** `Series Name/Series Name - 001.cbz` — Komga matches on
  folder + file names (add a ComicVine key for richer metadata).

The `[imdbid-...]` tag guarantees an exact match for films; title + year usually
works too.
