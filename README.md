# server-media-buddy

Helper scripts for managing my **Jellyfin + Komga** media server — the tooling
side of the setup documented in [`media-server-setup.md`](media-server-setup.md).

It does two jobs: **rename downloaded video into Jellyfin's folder layout**
(looking titles up on TMDB) and **rsync films, TV shows, and comics** from a
local machine into the server's media libraries. Everything is reachable from
one menu via `./buddy`. More content-management helpers will land here as the
server grows.

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

- `buddy` — the entry point: an interactive menu (or subcommands) that wraps everything below.
- `config.sh` — shared settings (server address, destination + default source folders, TMDB key). **Git-ignored** — copy it from `config-example.sh` and edit.
- `config-example.sh` — template for `config.sh` (safe to commit).
- `jellyfin-renamer.sh` — rename video files in place into Jellyfin's layout using TMDB lookups; asks you to pick when a title is ambiguous.
- `upload-films.sh` — upload films to the server's Films library (Jellyfin).
- `upload-tv.sh` — upload TV shows to the server's TV library (Jellyfin).
- `upload-comics.sh` — upload comics to the server's Comics library (Komga).

## Setup

1. Create your config from the template and edit it:
   ```bash
   cp config-example.sh config.sh
   # edit config.sh with your server address, paths and TMDB key
   ```
   The renamer needs a (free) TMDB API key: themoviedb.org → Settings → API,
   paste the *v3 auth* key into `TMDB_API_KEY`.
2. Make the scripts executable:
   ```bash
   chmod +x buddy jellyfin-renamer.sh upload-films.sh upload-tv.sh upload-comics.sh config.sh
   ```
3. Install the renamer's dependencies if missing: `curl` and `jq`
   (`sudo apt install curl jq`).
4. (Recommended) Set up SSH key auth so you're not prompted for a password each time:
   ```bash
   ssh-copy-id tbonks@192.168.0.33
   ```

## Usage

### The menu

```bash
./buddy
```

```
 __  __  ___  ___   ___    _      ___  _   _  ___   ___  __   __
|  \/  || __||   \ |_ _|  /_\    | _ )| | | ||   \ |   \ \ \ / /
| |\/| || _| | |) | | |  / _ \   | _ \| |_| || |) || |) | \ V /
|_|  |_||___||___/ |___|/_/ \_\  |___/ \___/ |___/ |___/   |_|
          S E R V E R   B U D D Y   ·   Jellyfin + Komga

 ┌─ setup ───────────────────────────────────────────────────────┐
 │ server    user@192.168.0.33                                    │
 │ films     /home/you/Downloads/to_upload_films/                 │
 │ tv        /home/you/Downloads/to_upload_series/                │
 │ comics    /home/you/Downloads/to_upload_comics/                │
 │ tmdb key  set                                                  │
 └────────────────────────────────────────────────────────────────┘

 ┌─ what do you want to do? ─────────────────────────────────────┐
 │   1   Upload films     ->  /mnt/media/Media/Films/             │
 │   2   Upload TV        ->  /mnt/media/Media/TV/                │
 │   3   Upload comics    ->  /mnt/media/Media/Comics/            │
 │   4   Rename for Jellyfin (TMDB lookup, in place)              │
 │   5   Rename dry run   (show the plan, change nothing)         │
 │   q   Quit                                                     │
 └────────────────────────────────────────────────────────────────┘
```

Each option asks for a folder (enter accepts the default from `config.sh`),
runs the matching script, and drops you back at the menu.

The same actions are available as subcommands for scripting:
```bash
./buddy films  [folder]
./buddy tv     [folder]
./buddy comics [folder]
./buddy rename [-n] <folder>
```

### Typical flow

1. Torrent finishes into `~/Downloads/to_upload_series/`.
2. `./buddy` → **5** (dry run) to see what the renamer would do; then **4** to
   apply it.
3. `./buddy` → **2** to rsync the tidied folder to the server.

### Renaming for Jellyfin

```bash
./jellyfin-renamer.sh -n ~/Downloads/to_upload_series   # dry run
./jellyfin-renamer.sh    ~/Downloads/to_upload_series   # rename (asks y/N first)
```

- Scans the folder recursively for video files and parses each name:
  `SxxExx` / `1x02` → TV episode, `Title.Year` → film. Release-group noise
  (`1080p`, `WEB-DL`, `x265`, `-NTb`…) is stripped before searching TMDB.
- A single TMDB hit, or a unique exact title(+year) match, is accepted
  automatically. Anything else shows a numbered prompt:

  ```
  ── The.Office.S02E03.720p.mkv
     parsed as: "The Office" · tv S2E3
     1) The Office (2005)
        US version…
     2) The Office (2001)
        UK version…
     s) skip this file   q) search with a different title   t) treat as film
     choice:
  ```

  `q` lets you retype the title/year, `t` flips TV ↔ film.
- Lookups and your picks are cached per title, so a whole season only asks once.
- It prints the full plan and asks for confirmation before moving anything.
  Existing destination files are never overwritten; folders emptied by a move
  are removed. Re-running on an already-tidied folder is a no-op.
- Only video files are moved — subtitles/`.nfo` next to them are left behind.

### Uploading directly

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

For best metadata matching (this is what `jellyfin-renamer.sh` produces):

- **Films (Jellyfin):** `Title (Year) [imdbid-ttXXXXXXX]/Title (Year) [imdbid-ttXXXXXXX].mkv`
- **TV (Jellyfin):** `Show (Year) [imdbid-ttXXXXXXX]/Season 01/Show (Year) - S01E01.mkv`
- **Comics (Komga):** `Series Name/Series Name - 001.cbz` — Komga matches on
  folder + file names (add a ComicVine key for richer metadata). Not handled by
  the renamer.

The `[imdbid-...]` tag guarantees an exact match; title + year usually works
too.
