#!/bin/bash

# --- 1. Essential Packages ---
PACKAGES="hyprland waybar kitty rofi yazi ranger stow git zsh tmux pipewire wireplumber xdg-desktop-portal-hyprland github-cli swaybg eza bat zsh-autosuggestions zsh-syntax-highlighting"

echo "Refreshing package database and installing essential packages..."
if command -v pacman &> /dev/null; then
    sudo pacman -Sy --needed --noconfirm $PACKAGES
fi

# --- 2. Oh My Zsh & Plugins ---
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    echo "Installing Oh My Zsh..."
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    # Remove the default .zshrc created by oh-my-zsh so stow can link our own
    rm -f "$HOME/.zshrc"
fi

ZSH_CUSTOM=${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}
[ ! -d "$ZSH_CUSTOM/themes/powerlevel10k" ] && git clone --depth=1 https://github.com/romkatv/powerlevel10k.git $ZSH_CUSTOM/themes/powerlevel10k

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

# Ensure target directories exist in ~ before stowing
mkdir -p ~/.config
stow -v -t ~ $PACKAGES_TO_STOW

# --- 5. Change Default Shell ---
if [ "$SHELL" != "$(which zsh)" ]; then
    echo "Changing default shell to zsh..."
    sudo chsh -s $(which zsh) $USER
fi

# --- 6. Apply Changes ---
if command -v hyprctl &> /dev/null; then
    echo "Forcefully exiting Hyprland to apply all changes..."
    hyprctl dispatch exit
fi

echo "Setup complete! Please restart your shell or run 'zsh'."

