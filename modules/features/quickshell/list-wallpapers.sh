#!/usr/bin/env bash

# list-wallpapers — print absolute paths of the image files in ~/wallpapers.
# Used by the Quickshell wallpaper picker. Prints nothing if the folder is
# missing or empty; the picker shows an empty state in that case.

set -euo pipefail

dir="${WALLPAPER_DIR:-$HOME/wallpapers}"

if [ ! -d "$dir" ]; then
  exit 0
fi

find "$dir" -maxdepth 1 -type f \( \
  -iname '*.png' -o \
  -iname '*.jpg' -o \
  -iname '*.jpeg' -o \
  -iname '*.gif' -o \
  -iname '*.webp' \
\) -print | sort
