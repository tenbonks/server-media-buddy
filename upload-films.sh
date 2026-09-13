#!/bin/bash
# Upload films to the media server.
# Usage:
#   ./upload-films.sh                 # uses FILMS_SRC_DEFAULT from config.sh
#   ./upload-films.sh /path/to/films  # uploads the contents of the given folder
set -euo pipefail
source "$(dirname "$0")/config.sh"

SRC="${1:-$FILMS_SRC_DEFAULT}"
# ensure trailing slash so the CONTENTS land in the destination, not a nested folder
[[ "$SRC" != */ ]] && SRC="$SRC/"

if [[ ! -d "$SRC" ]]; then
  echo "Error: source folder does not exist: $SRC" >&2
  exit 1
fi

echo "Uploading films"
echo "  from: $SRC"
echo "  to:   $SERVER:$FILMS_DEST"
echo

# --no-perms/owner/group: destination is NTFS, preserving Linux perms is pointless
# and noisy. Remove these once the server drive is ext4 if you want perms preserved.
rsync -avP --no-perms --no-owner --no-group "$SRC" "$SERVER:$FILMS_DEST"

echo
echo "Done."
