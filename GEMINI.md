# Agent Instructions for Dotfiles Repository

This repository contains the user's dotfiles managed by **GNU Stow**.

## Key Information
- **Stow Packages**: The directories at the root (e.g., `hypr`, `kitty`, `waybar`, `rofi`, `ranger`, `zsh`, `tmux`, `git`, `wallpapers`) are stow packages. Their contents are meant to be symlinked to the user's home directory (`~`).
- **Install Script**: `install.sh` is the primary entrypoint for setting up a new machine or syncing changes. It handles:
  - Arch package installation (via `pacman`).
  - Oh My Zsh setup and plugin cloning.
  - Nerd Font installation (JetBrainsMono, CaskaydiaCove).
  - Running `stow` to create symlinks.
  - Changing the default shell to `zsh`.
  - Forcefully exiting Hyprland to apply changes.
- **Machine-Specific Configs**: The `hyprland.conf` includes a `source = ~/.config/hypr/local.conf` line for machine-specific overrides (like monitor layouts and input sensitivity). `local.conf` is intentionally NOT tracked in this repository so each machine can have its own settings.

## Critical History & Resolved Bugs
When debugging issues, be aware of the following history:

1. **The Destructive Cleanup Loop Bug**: A previous version of `install.sh` contained a `find` loop intended to delete conflicting default files before running `stow`. However, because `stow` often symlinks the *parent directory* (e.g., `~/.config/hypr` becomes a symlink pointing into the repo), the files *inside* that directory were seen as regular files by the script. This caused the script to delete the user's custom configurations directly out of the git repository. **DO NOT re-introduce automated file deletion logic without extreme caution regarding symlinked parent directories.**
2. **Hyprland Autogeneration**: Due to the bug above, Hyprland repeatedly generated a default config inside the repo. The true custom configs were recovered from the user's other machine via SSH.
3. **Hyprland Exit Bind**: The `Super + M` keybind was simplified to use `hyprctl dispatch exit` instead of a custom script, ensuring it works reliably on fresh installs.
4. **Wallpaper Setup**: The wallpaper is stored in `wallpapers/wallpapers/` and is applied using a script (`wallpaper.sh`) that relies on `swaybg`.

## Standard Debugging Workflow
If the user reports issues on a new machine:
1. Run `git status` and `git log` to ensure they have pulled the latest authentic configurations.
2. Check if `stow` failed due to existing files. If it did, manually (or carefully) advise the user to remove the conflicting default file in their `~/.config` directory, but remember the lesson from bug #1.
3. If Hyprland or Waybar is failing, check the logs at `$XDG_RUNTIME_DIR/hypr/*/hyprland.log` or run `waybar` in a terminal to see the output.
4. Verify that the necessary packages (`swaybg`, fonts, etc.) were successfully installed by `install.sh`.