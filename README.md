# Media Upload Scripts

Small helper scripts to rsync films and TV shows from a local machine to the
media server.

## Files

- `config.sh` — shared settings (server address, destination + default source folders). Edit this first.
- `upload-films.sh` — upload films to the server's Films library.
- `upload-tv.sh` — upload TV shows to the server's TV library.

## Setup

1. Edit `config.sh` with your server address and paths.
2. Make the scripts executable:
   ```bash
   chmod +x upload-films.sh upload-tv.sh config.sh
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
```

Or pass a specific folder to upload the contents of:
```bash
./upload-films.sh "/path/to/some/films/"
./upload-tv.sh "/path/to/some/tv/"
```

## Notes

- The scripts add a trailing slash to the source automatically, so the
  **contents** of the source folder land in the destination (not nested inside
  another folder).
- `rsync -avP` gives archive mode, progress, and resume — if a transfer drops,
  just run the same command again and it picks up where it left off.
- `--no-perms --no-owner --no-group` are set because the server drive is
  currently **NTFS**, where preserving Linux permissions is pointless and noisy.
  Remove these flags once the drive is **ext4** if you want ownership/permissions
  preserved.
- Make sure the media drive is mounted and the stack is running on the server
  before uploading.
- After uploading, trigger a library scan in Jellyfin (or wait for the scheduled
  one) to pull new media in with metadata.

## File naming

For best metadata matching in Jellyfin:

- **Films:** `Title (Year) [imdbid-ttXXXXXXX]/Title (Year).mkv`
- **TV:** `Show Name/Season 01/Show Name - S01E01.mkv`

The `[imdbid-...]` tag guarantees an exact match; title + year usually works too.
# server-media-buddy
