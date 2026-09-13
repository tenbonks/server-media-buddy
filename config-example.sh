#!/bin/bash
# Shared config for the media upload scripts.
# Edit these values to match your setup.
SERVER="username@192.168.0.33"

# Destinations on the server (trailing slash matters)
FILMS_DEST="/mnt/media/Media/Films/"
TV_DEST="/mnt/media/Media/TV/"
COMICS_DEST="/mnt/media/Media/Comics/"

# Default local source folders (used when no folder is passed as an argument)
FILMS_SRC_DEFAULT="$HOME/Downloads/to_upload_films/"
TV_SRC_DEFAULT="$HOME/Downloads/to_upload_series/"
COMICS_SRC_DEFAULT="$HOME/Downloads/to_upload_comics/"
