#!/usr/bin/env bash
# Alt+Tab workspace switcher using rofi.
# Shows workspace previews (window layout minimap + workspace number)
# in a horizontal grid. Accept on Alt release via rofi's ! prefix.
#
# Note: hyprctl reload does not re-run exec-once. If you pkill the MRU
# daemon, it is started again automatically the next time this script runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=workspace-mru-lib.sh
source "${SCRIPT_DIR}/workspace-mru-lib.sh"

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/hypr"
MRU_FILE="${CACHE_DIR}/workspace_mru"
PREVIEW_DIR="${CACHE_DIR}/workspace_previews"
RUN_LOCK="${CACHE_DIR}/workspace_alt_tab.run.lock"
THEME="${SCRIPT_DIR}/workspace-alt-tab.rasi"
PREVIEW_W=128
MAX_COLUMNS=5
MAX_PREVIEW_JOBS=4

mkdir -p "${CACHE_DIR}" "${PREVIEW_DIR}"

# One switcher at a time (fast Alt+Tab would spawn overlapping runs and break rofi).
exec 200>"${RUN_LOCK}"
flock -n 200 || exit 0

command -v hyprctl >/dev/null 2>&1 || exit 1
command -v jq >/dev/null 2>&1 || exit 1
command -v rofi >/dev/null 2>&1 || exit 1

# hyprctl reload does not re-run exec-once; restart MRU if it was pkill'd.
ensure_mru_daemon() {
  [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && return 0
  local daemon="${SCRIPT_DIR}/workspace-mru-daemon.sh"
  [[ -f "${daemon}" ]] || return 0
  if ! pgrep -f "workspace-mru-daemon\.sh" >/dev/null 2>&1; then
    "${daemon}" >/dev/null 2>&1 &
  fi
}

ensure_mru_daemon

# --- Query Hyprland state (parallel hyprctl) ---
ws_json="" clients_json="" monitors_json=""
ws_json="$(hyprctl -j workspaces 2>/dev/null || echo '[]')" &
clients_json="$(hyprctl -j clients 2>/dev/null || echo '[]')" &
monitors_json="$(hyprctl -j monitors 2>/dev/null || echo '[]')" &
wait || true

# Focused monitor for aspect ratio
mon_w="$(echo "${monitors_json}" | jq '[.[] | select(.focused)] | .[0].width // 1920')"
mon_h="$(echo "${monitors_json}" | jq '[.[] | select(.focused)] | .[0].height // 1080')"
PREVIEW_H=$(( PREVIEW_W * mon_h / mon_w ))

mapfile -t all_ids < <(echo "${ws_json}" | jq -r '.[] | select(.id > 0) | .id | tostring' | sort -n)
(( ${#all_ids[@]} <= 1 )) && exit 0

# --- Order: current workspace first, then MRU (previous, then older), then rest by id ---
active_id="$(echo "${monitors_json}" | jq -r '[.[] | select(.focused == true)] | .[0].activeWorkspace.id // empty')"
if [[ -z "${active_id}" || "${active_id}" == "null" ]]; then
  active_id="$(hyprctl -j activeworkspace 2>/dev/null | jq -r '.id // empty')"
fi
active_id="${active_id//$'\r'/}"
[[ -z "${active_id}" || "${active_id}" == "null" ]] && active_id=""
if [[ -n "${active_id}" ]]; then
  active_id="${active_id#"${active_id%%[![:space:]]*}"}"
  active_id="${active_id%"${active_id##*[![:space:]]}"}"
fi

if [[ -n "${active_id}" ]]; then
  first_in_mru=""
  if [[ -f "${MRU_FILE}" ]]; then
    first_in_mru="$(head -n1 "${MRU_FILE}" | tr -d '\r')"
    first_in_mru="${first_in_mru#"${first_in_mru%%[![:space:]]*}"}"
    first_in_mru="${first_in_mru%"${first_in_mru##*[![:space:]]}"}"
  fi
  if [[ "${first_in_mru}" != "${active_id}" ]]; then
    prepend_mru_atomic "${CACHE_DIR}" "${active_id}"
  fi
fi

declare -A ws_exists=()
for id in "${all_ids[@]}"; do ws_exists["${id}"]=1; done

ordered_ids=()
declare -A seen=()

if [[ -n "${active_id}" && -n "${ws_exists[${active_id}]+x}" ]]; then
  ordered_ids+=("${active_id}")
  seen["${active_id}"]=1
fi

if [[ -f "${MRU_FILE}" ]]; then
  while IFS= read -r id; do
    id="${id//$'\r'/}"
    id="${id#"${id%%[![:space:]]*}"}"
    id="${id%"${id##*[![:space:]]}"}"
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

# --- Precompute maps (one jq each) ---
mon_map="$(echo "${monitors_json}" | jq -c '[.[] | {(.name): {x: .x, y: .y}}] | add // {}')"
ws_mon_map="$(echo "${ws_json}" | jq -c '[.[] | select(.id > 0) | {(.id | tostring): .monitor}] | add // {}')"
rects_by_ws="$(
  echo "${clients_json}" | jq -c '
    [ .[] | select(.mapped and (.hidden | not) and (.workspace.id > 0)) ]
    | group_by(.workspace.id)
    | map({ (.[0].workspace.id | tostring): map([.at[0], .at[1], .size[0], .size[1]]) })
    | add // {}
  '
)"

MAGICK=""
command -v magick >/dev/null 2>&1 && MAGICK="magick"
[[ -z "${MAGICK}" ]] && command -v convert >/dev/null 2>&1 && MAGICK="convert"

preview_signature() {
  local id="$1" win_json="$2" mx="$3" my="$4"
  printf '%s|%s|%s|%s|%s|%s|%s' "${win_json}" "${mx}" "${my}" "${mon_w}" "${mon_h}" "${PREVIEW_W}" "${PREVIEW_H}" \
    | sha256sum | awk '{print $1}'
}

generate_preview_magick() {
  local ws_id="$1" win_json="$2" mx="$3" my="$4" preview_path="$5"

  [[ -z "${MAGICK}" ]] && return 0

  local win_count
  win_count="$(jq 'length' <<< "${win_json}")"

  local -a draw_cmds=()
  local i wx wy ww wh rx1 ry1 rx2 ry2
  for (( i=0; i<win_count; i++ )); do
    read -r wx wy ww wh < <(jq -r --argjson i "${i}" '.[$i] | "\(.[0]) \(.[1]) \(.[2]) \(.[3])"' <<< "${win_json}")
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
    -define png:compression-level=3 \
    -fill "#22232e" -stroke "#3a3d4e" -strokewidth 1 \
    -draw "roundrectangle 1,1 $(( PREVIEW_W-2 )),$(( PREVIEW_H-2 )) 4,4" \
    ${draw_cmds[@]+"${draw_cmds[@]}"} \
    -gravity center -pointsize 32 -fill "#ffffff40" -annotate 0 "${ws_id}" \
    "${preview_path}" 2>/dev/null
}

_run_one_preview() {
  local id="$1" win_json="$2" mx="$3" my="$4"
  local preview_path="${PREVIEW_DIR}/ws_${id}.png"
  local sig_path="${PREVIEW_DIR}/ws_${id}.sig"
  local sig
  [[ -z "${MAGICK}" ]] && return 0
  sig="$(preview_signature "${id}" "${win_json}" "${mx}" "${my}")"
  if [[ -f "${preview_path}" && -f "${sig_path}" && "$(<"${sig_path}")" == "${sig}" ]]; then
    return 0
  fi
  printf '%s' "${sig}" > "${sig_path}.tmp"
  if generate_preview_magick "${id}" "${win_json}" "${mx}" "${my}" "${preview_path}"; then
    mv "${sig_path}.tmp" "${sig_path}"
  else
    rm -f "${sig_path}.tmp"
  fi
}

preview_pids=()
for id in "${ordered_ids[@]}"; do
  ws_mon="$(jq -r --arg i "${id}" '.[$i] // ""' <<< "${ws_mon_map}")"
  if [[ -z "${ws_mon}" ]]; then
    mx=0 my=0
  else
    mx="$(jq -r --arg m "${ws_mon}" '.[$m].x // 0' <<< "${mon_map}")"
    my="$(jq -r --arg m "${ws_mon}" '.[$m].y // 0' <<< "${mon_map}")"
  fi
  win_json="$(jq -c --arg i "${id}" '.[$i] // []' <<< "${rects_by_ws}")"
  while (( ${#preview_pids[@]} >= MAX_PREVIEW_JOBS )); do
    wait "${preview_pids[0]}"
    preview_pids=("${preview_pids[@]:1}")
  done
  _run_one_preview "${id}" "${win_json}" "${mx}" "${my}" &
  preview_pids+=("$!")
done
for pid in "${preview_pids[@]}"; do
  wait "${pid}"
done

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

selected_id="$(echo "${ws_json}" | jq -r --arg name "${selected_name}" \
  '.[] | select(.name == $name) | .id' | head -n 1)"
[[ -z "${selected_id}" || "${selected_id}" == "null" ]] && exit 0

hyprctl dispatch focusworkspaceoncurrentmonitor "${selected_id}" >/dev/null 2>&1 || true
prepend_mru_atomic "${CACHE_DIR}" "${selected_id}"
