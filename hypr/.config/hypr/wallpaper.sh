#!/bin/bash
# Randomly pick and set a wallpaper from the wallpapers directory using swaybg

WALLPAPER_DIR="$HOME/projects/dotfiles/wallpapers"

# Kill any existing swaybg instance
pkill swaybg 2>/dev/null

# Find image files
mapfile -t walls < <(find "$WALLPAPER_DIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.bmp' \) 2>/dev/null)

if [ ${#walls[@]} -eq 0 ]; then
    echo "No wallpapers found in $WALLPAPER_DIR"
    exit 1
fi

# Pick a random wallpaper
WALLPAPER="${walls[RANDOM % ${#walls[@]}]}"

# Set wallpaper
swaybg -i "$WALLPAPER" -m fill &
disown
