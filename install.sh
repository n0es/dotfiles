#!/bin/bash

# --- 1. Essential Packages ---
PACKAGES="hyprland waybar kitty rofi yazi ranger stow git zsh tmux pipewire wireplumber xdg-desktop-portal-hyprland github-cli"

echo "Refreshing package database and installing essential packages..."
if command -v pacman &> /dev/null; then
    sudo pacman -Sy --needed --noconfirm $PACKAGES
fi

# --- 2. Oh My Zsh & Plugins ---
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    echo "Installing Oh My Zsh..."
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

ZSH_CUSTOM=${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}
[ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ] && git clone https://github.com/zsh-users/zsh-syntax-highlighting.git $ZSH_CUSTOM/plugins/zsh-syntax-highlighting
[ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ] && git clone https://github.com/zsh-users/zsh-autosuggestions.git $ZSH_CUSTOM/plugins/zsh-autosuggestions

# --- 3. Nerd Fonts (JetBrainsMono & CaskaydiaCove) ---
mkdir -p ~/.local/share/fonts
cd /tmp

install_font() {
    local font_name=$1
    local url=$2
    if ! fc-list | grep -qi "$font_name"; then
        echo "Installing $font_name Nerd Font..."
        curl -OL "$url"
        tar -xf "$(basename "$url")" -C ~/.local/share/fonts
    fi
}

install_font "JetBrainsMono" "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz"
install_font "CaskaydiaCove" "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/CascadiaCode.tar.xz"

fc-cache -fv
cd -

# --- 4. Stow Symlinks ---
echo "Applying dotfiles with Stow..."
cd ~/projects/dotfiles

# List of packages to stow
PACKAGES_TO_STOW="hypr kitty waybar rofi yazi ranger zsh tmux git wallpapers"

# Cleanup conflicting files before stowing
# This removes existing files that aren't symlinks so stow can take over
for pkg in $PACKAGES_TO_STOW; do
    echo "Preparing $pkg..."
    # Find all files in the package that would be stowed
    find "$pkg" -type f | sed "s|^$pkg/||" | while read -r file; do
        target="$HOME/$file"
        if [ -f "$target" ] && [ ! -L "$target" ]; then
            echo "Removing existing file: $target"
            rm "$target"
        fi
    done
done

# Ensure target directories exist in ~ before stowing
mkdir -p ~/.config
stow -v -t ~ $PACKAGES_TO_STOW

# --- 5. Apply Changes ---
if command -v hyprctl &> /dev/null; then
    echo "Reloading Hyprland configuration..."
    hyprctl reload
fi

echo "Setup complete! Please restart your shell or run 'zsh'."

