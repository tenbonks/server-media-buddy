#!/bin/bash
# Upload TV shows to the media server.
# Usage:
#   ./upload-tv.sh                # uses TV_SRC_DEFAULT from config.sh
#   ./upload-tv.sh /path/to/tv    # uploads the contents of the given folder
set -euo pipefail
source "$(dirname "$0")/config.sh"

SRC="${1:-$TV_SRC_DEFAULT}"
# ensure trailing slash so the CONTENTS land in the destination, not a nested folder
[[ "$SRC" != */ ]] && SRC="$SRC/"

if [[ ! -d "$SRC" ]]; then
  echo "Error: source folder does not exist: $SRC" >&2
  exit 1
fi

echo "Uploading TV"
echo "  from: $SRC"
echo "  to:   $SERVER:$TV_DEST"
echo

# --no-perms/owner/group: destination is NTFS, preserving Linux perms is pointless
# and noisy. Remove these once the server drive is ext4 if you want perms preserved.
rsync -avP --no-perms --no-owner --no-group "$SRC" "$SERVER:$TV_DEST"

echo
echo "Done."
