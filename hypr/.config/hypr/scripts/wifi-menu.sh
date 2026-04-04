#!/bin/bash
# Toggle wifi menu

if pgrep -f "wifi-menu.py" >/dev/null; then
    pkill -f "wifi-menu.py"
    exit 0
fi

exec python3 ~/.config/hypr/scripts/wifi-menu.py
