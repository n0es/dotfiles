#!/usr/bin/env bash
# Alt+Tab workspace switcher using rofi.
# Builds an MRU-ordered workspace list, launches rofi with release-accept
# bindings so the selection is confirmed when Alt is released.

set -euo pipefail

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/hypr"
MRU_FILE="${CACHE_DIR}/workspace_mru"
PREVIEW_DIR="${CACHE_DIR}/workspace_previews"
THEME="$HOME/.config/hypr/scripts/workspace-alt-tab.rasi"
mkdir -p "${CACHE_DIR}" "${PREVIEW_DIR}"

command -v hyprctl >/dev/null 2>&1 || exit 1
command -v jq >/dev/null 2>&1 || exit 1
command -v rofi >/dev/null 2>&1 || exit 1

ws_json="$(hyprctl -j workspaces 2>/dev/null || echo '[]')"

mapfile -t all_ids < <(echo "${ws_json}" | jq -r '.[] | select(.id > 0) | .id | tostring' | sort -n)

if [[ ${#all_ids[@]} -le 1 ]]; then
  exit 0
fi

# --- MRU ordering ---
declare -A ws_exists=()
for id in "${all_ids[@]}"; do
  ws_exists["${id}"]=1
done

ordered_ids=()
declare -A seen=()

if [[ -f "${MRU_FILE}" ]]; then
  while IFS= read -r id; do
    [[ -z "${id}" ]] && continue
    if [[ -n "${ws_exists[${id}]+x}" && -z "${seen[${id}]+x}" ]]; then
      ordered_ids+=("${id}")
      seen["${id}"]=1
    fi
  done < "${MRU_FILE}"
fi

for id in "${all_ids[@]}"; do
  if [[ -z "${seen[${id}]+x}" ]]; then
    ordered_ids+=("${id}")
    seen["${id}"]=1
  fi
done

# --- Generate placeholder preview images ---
ensure_preview() {
  local ws_id="$1"
  local preview_path="${PREVIEW_DIR}/ws_${ws_id}.png"

  if [[ -f "${preview_path}" ]]; then
    printf '%s' "${preview_path}"
    return
  fi

  # Generate a 160x90 (16:9) solid color placeholder.
  # Cycle through a small palette so workspaces are visually distinct.
  local -a colors=("2e3440" "3b4252" "434c5e" "4c566a" "5e81ac" "81a1c1" "88c0d0" "8fbcbb")
  local color_idx=$(( ws_id % ${#colors[@]} ))
  local hex="${colors[${color_idx}]}"

  if command -v magick >/dev/null 2>&1; then
    magick -size 160x90 "xc:#${hex}" "${preview_path}" 2>/dev/null
  elif command -v convert >/dev/null 2>&1; then
    convert -size 160x90 "xc:#${hex}" "${preview_path}" 2>/dev/null
  else
    # Minimal 1x1 PNG fallback (base64-decoded), scaled concept only
    printf '\x89PNG\r\n\x1a\n' > "${preview_path}" 2>/dev/null || true
  fi

  printf '%s' "${preview_path}"
}

# --- Build rofi input ---
rofi_input=""
for id in "${ordered_ids[@]}"; do
  ws_name="$(echo "${ws_json}" | jq -r --argjson id "${id}" '.[] | select(.id == $id) | .name')"
  preview="$(ensure_preview "${id}")"
  if [[ -z "${rofi_input}" ]]; then
    rofi_input="${ws_name}\0icon\x1fthumbnail://${preview}"
  else
    rofi_input="${rofi_input}\n${ws_name}\0icon\x1fthumbnail://${preview}"
  fi
done

# --- Launch rofi ---
selected_name="$(
  printf '%b' "${rofi_input}" | rofi -dmenu \
    -theme "${THEME}" \
    -show-icons \
    -selected-row 1 \
    -steal-focus \
    -no-lazy-grab \
    -kb-accept-entry '!Alt_L,!Alt+Alt_L,Return' \
    -kb-element-next 'Alt+Tab' \
    -kb-element-prev 'Alt+ISO_Left_Tab' \
    -kb-cancel 'Alt+Escape,Escape' \
    -kb-row-up '' \
    -kb-row-down '' \
    -p ''
)" || exit 0

[[ -z "${selected_name}" ]] && exit 0

# --- Find workspace ID by name and dispatch ---
selected_id="$(echo "${ws_json}" | jq -r --arg name "${selected_name}" '.[] | select(.name == $name) | .id' | head -n 1)"
[[ -z "${selected_id}" || "${selected_id}" == "null" ]] && exit 0

hyprctl dispatch focusworkspaceoncurrentmonitor "${selected_id}" >/dev/null 2>&1 || true
