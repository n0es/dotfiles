#!/usr/bin/env bash
# Alt+Tab workspace switcher using rofi.
# Shows workspace previews (window layout minimap + workspace number)
# in a horizontal grid. Accept on Alt release via rofi's ! prefix.

set -euo pipefail

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/hypr"
MRU_FILE="${CACHE_DIR}/workspace_mru"
PREVIEW_DIR="${CACHE_DIR}/workspace_previews"
THEME="$HOME/.config/hypr/scripts/workspace-alt-tab.rasi"
PREVIEW_W=192
MAX_COLUMNS=5

mkdir -p "${CACHE_DIR}" "${PREVIEW_DIR}"

pgrep -f "rofi.*workspace-alt-tab" >/dev/null 2>&1 && exit 0

command -v hyprctl >/dev/null 2>&1 || exit 1
command -v jq >/dev/null 2>&1 || exit 1
command -v rofi >/dev/null 2>&1 || exit 1

# --- Query Hyprland state (batch all queries upfront) ---
ws_json="$(hyprctl -j workspaces 2>/dev/null || echo '[]')"
clients_json="$(hyprctl -j clients 2>/dev/null || echo '[]')"
monitors_json="$(hyprctl -j monitors 2>/dev/null || echo '[]')"

# Focused monitor for aspect ratio
mon_w="$(echo "${monitors_json}" | jq '[.[] | select(.focused)] | .[0].width // 1920')"
mon_h="$(echo "${monitors_json}" | jq '[.[] | select(.focused)] | .[0].height // 1080')"
PREVIEW_H=$(( PREVIEW_W * mon_h / mon_w ))

mapfile -t all_ids < <(echo "${ws_json}" | jq -r '.[] | select(.id > 0) | .id | tostring' | sort -n)
(( ${#all_ids[@]} <= 1 )) && exit 0

# --- MRU ordering ---
declare -A ws_exists=()
for id in "${all_ids[@]}"; do ws_exists["${id}"]=1; done

ordered_ids=()
declare -A seen=()

if [[ -f "${MRU_FILE}" ]]; then
  while IFS= read -r id; do
    [[ -z "${id}" ]] && continue
    [[ -n "${ws_exists[${id}]+x}" && -z "${seen[${id}]+x}" ]] || continue
    ordered_ids+=("${id}")
    seen["${id}"]=1
  done < "${MRU_FILE}"
fi

for id in "${all_ids[@]}"; do
  [[ -z "${seen[${id}]+x}" ]] || continue
  ordered_ids+=("${id}")
  seen["${id}"]=1
done

# --- Preview generation ---
MAGICK=""
command -v magick >/dev/null 2>&1 && MAGICK="magick"
[[ -z "${MAGICK}" ]] && command -v convert >/dev/null 2>&1 && MAGICK="convert"

rm -f "${PREVIEW_DIR}"/ws_*.png 2>/dev/null || true

generate_preview() {
  local ws_id="$1"
  local preview_path="${PREVIEW_DIR}/ws_${ws_id}.png"

  [[ -z "${MAGICK}" ]] && return 0

  local ws_monitor mx my
  ws_monitor="$(echo "${ws_json}" | jq -r --argjson id "${ws_id}" '.[] | select(.id == $id) | .monitor')"
  mx="$(echo "${monitors_json}" | jq --arg m "${ws_monitor}" '[.[] | select(.name == $m)] | .[0].x // 0')"
  my="$(echo "${monitors_json}" | jq --arg m "${ws_monitor}" '[.[] | select(.name == $m)] | .[0].y // 0')"

  local win_data win_count
  win_data="$(echo "${clients_json}" | jq -c --argjson wsid "${ws_id}" \
    '[.[] | select(.workspace.id == $wsid and .mapped and (.hidden | not))]')"
  win_count="$(echo "${win_data}" | jq 'length')"

  local -a draw_cmds=()
  local i wx wy ww wh rx1 ry1 rx2 ry2
  for (( i=0; i<win_count; i++ )); do
    read -r wx wy ww wh < <(echo "${win_data}" | jq -r --argjson i "${i}" \
      '.[$i] | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')
    wx=$(( wx - mx ))
    wy=$(( wy - my ))
    rx1=$(( wx * PREVIEW_W / mon_w + 2 ))
    ry1=$(( wy * PREVIEW_H / mon_h + 2 ))
    rx2=$(( (wx + ww) * PREVIEW_W / mon_w + 2 ))
    ry2=$(( (wy + wh) * PREVIEW_H / mon_h + 2 ))
    (( rx1 < 2 )) && rx1=2
    (( ry1 < 2 )) && ry1=2
    (( rx2 >= PREVIEW_W - 2 )) && rx2=$(( PREVIEW_W - 3 ))
    (( ry2 >= PREVIEW_H - 2 )) && ry2=$(( PREVIEW_H - 3 ))
    draw_cmds+=(-fill "#3d4555" -stroke "#5e6779" -strokewidth 1 \
      -draw "rectangle ${rx1},${ry1} ${rx2},${ry2}")
  done

  "${MAGICK}" -size "${PREVIEW_W}x${PREVIEW_H}" "xc:#1a1b26" \
    -fill "#22232e" -stroke "#3a3d4e" -strokewidth 1 \
    -draw "roundrectangle 1,1 $(( PREVIEW_W-2 )),$(( PREVIEW_H-2 )) 4,4" \
    ${draw_cmds[@]+"${draw_cmds[@]}"} \
    -gravity center -pointsize 40 -fill "#ffffff40" -annotate 0 "${ws_id}" \
    "${preview_path}" 2>/dev/null || true
}

for id in "${ordered_ids[@]}"; do
  generate_preview "${id}" &
done
wait || true

# --- Build rofi input ---
rofi_lines=()
for id in "${ordered_ids[@]}"; do
  ws_name="$(echo "${ws_json}" | jq -r --argjson id "${id}" '.[] | select(.id == $id) | .name')"
  preview="${PREVIEW_DIR}/ws_${id}.png"
  if [[ -f "${preview}" ]]; then
    rofi_lines+=("${ws_name}\0icon\x1f${preview}")
  else
    rofi_lines+=("${ws_name}")
  fi
done

num_ws="${#ordered_ids[@]}"
columns="${MAX_COLUMNS}"
(( num_ws < columns )) && columns="${num_ws}"
lines=$(( (num_ws + columns - 1) / columns ))

# --- Launch rofi ---
selected_name="$(
  for line in "${rofi_lines[@]}"; do
    printf '%b\n' "${line}"
  done | rofi -dmenu \
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
    -kb-row-tab '' \
    -p '' \
    -theme-str "listview { columns: ${columns}; lines: ${lines}; } element-icon { size: ${PREVIEW_W}px ${PREVIEW_H}px; }"
)" || exit 0

[[ -z "${selected_name}" ]] && exit 0

# --- Dispatch workspace switch ---
selected_id="$(echo "${ws_json}" | jq -r --arg name "${selected_name}" \
  '.[] | select(.name == $name) | .id' | head -n 1)"
[[ -z "${selected_id}" || "${selected_id}" == "null" ]] && exit 0

hyprctl dispatch focusworkspaceoncurrentmonitor "${selected_id}" >/dev/null 2>&1 || true
