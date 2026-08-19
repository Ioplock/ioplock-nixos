#!/usr/bin/env bash

# set-wallpaper — (re)start swaybg with the given image.
# niri renders swaybg's image as the compositor background, so it shows
# through semi-transparent layer-shell surfaces (like the status bar).

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: set-wallpaper <path>" >&2
  exit 2
fi

path="$1"

if [ ! -f "$path" ]; then
  echo "wallpaper not found: $path" >&2
  exit 1
fi

# Only one swaybg can own the compositor background at a time.
# NB: nixpkgs wraps swaybg, so the process shows up as ".swaybg-wrapped";
# `pkill -x swaybg` would not match. Match the full command line instead.
pkill -f 'swaybg' 2>/dev/null || true

exec swaybg -m fill -i "$path"