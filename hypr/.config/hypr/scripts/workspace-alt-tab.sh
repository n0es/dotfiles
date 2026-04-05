#!/usr/bin/env bash
# Alt+Tab workspace switcher using rofi.
# Shows workspace previews (window layout minimap + workspace number)
# in a horizontal grid. Accept on Alt release via rofi's ! prefix.
#
# Quick-tap handling: a wtype watchdog sends a synthetic Alt press+release
# after rofi starts. If Alt was already released, this triggers rofi's
# !Alt_L accept. If Alt is still physically held, wlroots merges key state
# across devices so Alt stays pressed until the real release.

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

exec 200>"${RUN_LOCK}"
flock -n 200 || exit 0

command -v hyprctl >/dev/null 2>&1 || exit 1
command -v jq >/dev/null 2>&1 || exit 1
command -v rofi >/dev/null 2>&1 || exit 1

ensure_mru_daemon() {
  [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && return 0
  local daemon="${SCRIPT_DIR}/workspace-mru-daemon.sh"
  [[ -f "${daemon}" ]] || return 0
  pgrep -f "workspace-mru-daemon\.sh" >/dev/null 2>&1 || "${daemon}" >/dev/null 2>&1 &
}
ensure_mru_daemon

# --- Query Hyprland state ---
_tmp_ws="$(mktemp)" _tmp_cl="$(mktemp)" _tmp_mon="$(mktemp)" _rofi_out="$(mktemp)"
trap 'rm -f "${_tmp_ws}" "${_tmp_cl}" "${_tmp_mon}" "${_rofi_out}"' EXIT
(hyprctl -j workspaces 2>/dev/null || echo '[]') > "${_tmp_ws}" &
(hyprctl -j clients 2>/dev/null || echo '[]') > "${_tmp_cl}" &
(hyprctl -j monitors 2>/dev/null || echo '[]') > "${_tmp_mon}" &
wait
ws_json="$(<"${_tmp_ws}")"
clients_json="$(<"${_tmp_cl}")"
monitors_json="$(<"${_tmp_mon}")"

mon_w="$(echo "${monitors_json}" | jq '[.[] | select(.focused)] | .[0].width // 1920')"
mon_h="$(echo "${monitors_json}" | jq '[.[] | select(.focused)] | .[0].height // 1080')"
PREVIEW_H=$(( PREVIEW_W * mon_h / mon_w ))

mapfile -t all_ids < <(echo "${ws_json}" | jq -r '.[] | select(.id > 0) | .id | tostring' | sort -n)
(( ${#all_ids[@]} <= 1 )) && exit 0

# --- MRU ordering ---
active_id="$(echo "${monitors_json}" | jq -r '[.[] | select(.focused == true)] | .[0].activeWorkspace.id // empty')"
if [[ -z "${active_id}" || "${active_id}" == "null" ]]; then
  active_id="$(hyprctl -j activeworkspace 2>/dev/null | jq -r '.id // empty')"
fi
active_id="${active_id//$'\r'/}"
[[ -z "${active_id}" || "${active_id}" == "null" ]] && active_id=""
active_id="${active_id#"${active_id%%[![:space:]]*}"}"
active_id="${active_id%"${active_id##*[![:space:]]}"}"

if [[ -n "${active_id}" && -f "${MRU_FILE}" ]]; then
  first_in_mru="$(head -n1 "${MRU_FILE}" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ "${first_in_mru}" != "${active_id}" ]] && prepend_mru_atomic "${CACHE_DIR}" "${active_id}"
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

# --- Preview generation ---
mon_map="$(echo "${monitors_json}" | jq -c '[.[] | {(.name): {x: .x, y: .y}}] | add // {}')"
ws_mon_map="$(echo "${ws_json}" | jq -c '[.[] | select(.id > 0) | {(.id | tostring): .monitor}] | add // {}')"
rects_by_ws="$(echo "${clients_json}" | jq -c '
  [ .[] | select(.mapped and (.hidden | not) and (.workspace.id > 0)) ]
  | group_by(.workspace.id)
  | map({ (.[0].workspace.id | tostring): map([.at[0], .at[1], .size[0], .size[1]]) })
  | add // {}
')"

MAGICK=""
command -v magick >/dev/null 2>&1 && MAGICK="magick"
[[ -z "${MAGICK}" ]] && command -v convert >/dev/null 2>&1 && MAGICK="convert"

generate_preview_magick() {
  local ws_id="$1" win_json="$2" mx="$3" my="$4" preview_path="$5"
  [[ -z "${MAGICK}" ]] && return 0

  local win_count
  win_count="$(jq 'length' <<< "${win_json}")"

  local -a draw_cmds=()
  local i wx wy ww wh rx1 ry1 rx2 ry2
  for (( i=0; i<win_count; i++ )); do
    read -r wx wy ww wh < <(jq -r --argjson i "${i}" '.[$i] | "\(.[0]) \(.[1]) \(.[2]) \(.[3])"' <<< "${win_json}")
    wx=$(( wx - mx )); wy=$(( wy - my ))
    rx1=$(( wx * PREVIEW_W / mon_w + 2 )); ry1=$(( wy * PREVIEW_H / mon_h + 2 ))
    rx2=$(( (wx + ww) * PREVIEW_W / mon_w + 2 )); ry2=$(( (wy + wh) * PREVIEW_H / mon_h + 2 ))
    (( rx1 < 2 )) && rx1=2; (( ry1 < 2 )) && ry1=2
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

preview_signature() {
  printf '%s|%s|%s|%s|%s|%s' "$2" "$3" "$4" "${mon_w}" "${mon_h}" "${PREVIEW_W}" \
    | sha256sum | awk '{print $1}'
}

_run_one_preview() {
  local id="$1" win_json="$2" mx="$3" my="$4"
  local pp="${PREVIEW_DIR}/ws_${id}.png" sp="${PREVIEW_DIR}/ws_${id}.sig"
  [[ -z "${MAGICK}" ]] && return 0
  local sig; sig="$(preview_signature "${id}" "${win_json}" "${mx}" "${my}")"
  [[ -f "${pp}" && -f "${sp}" && "$(<"${sp}")" == "${sig}" ]] && return 0
  printf '%s' "${sig}" > "${sp}.tmp"
  if generate_preview_magick "${id}" "${win_json}" "${mx}" "${my}" "${pp}"; then
    mv "${sp}.tmp" "${sp}"
  else
    rm -f "${sp}.tmp"
  fi
}

preview_pids=()
for id in "${ordered_ids[@]}"; do
  ws_mon="$(jq -r --arg i "${id}" '.[$i] // ""' <<< "${ws_mon_map}")"
  if [[ -n "${ws_mon}" ]]; then
    mx="$(jq -r --arg m "${ws_mon}" '.[$m].x // 0' <<< "${mon_map}")"
    my="$(jq -r --arg m "${ws_mon}" '.[$m].y // 0' <<< "${mon_map}")"
  else mx=0 my=0; fi
  win_json="$(jq -c --arg i "${id}" '.[$i] // []' <<< "${rects_by_ws}")"
  while (( ${#preview_pids[@]} >= MAX_PREVIEW_JOBS )); do
    wait "${preview_pids[0]}" 2>/dev/null || true
    preview_pids=("${preview_pids[@]:1}")
  done
  _run_one_preview "${id}" "${win_json}" "${mx}" "${my}" &
  preview_pids+=("$!")
done
for pid in "${preview_pids[@]}"; do wait "${pid}" 2>/dev/null || true; done

# --- Build rofi input ---
rofi_lines=()
for id in "${ordered_ids[@]}"; do
  ws_name="$(echo "${ws_json}" | jq -r --argjson id "${id}" '.[] | select(.id == $id) | .name')"
  preview="${PREVIEW_DIR}/ws_${id}.png"
  [[ -f "${preview}" ]] && rofi_lines+=("${ws_name}\0icon\x1f${preview}") || rofi_lines+=("${ws_name}")
done

num_ws="${#ordered_ids[@]}"
columns="${MAX_COLUMNS}"
(( num_ws < columns )) && columns="${num_ws}"
lines=$(( (num_ws + columns - 1) / columns ))

# --- Launch rofi ---
(
  for line in "${rofi_lines[@]}"; do printf '%b\n' "${line}"; done | rofi -dmenu \
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
) > "${_rofi_out}" &
ROFI_PID=$!

# Watchdog: send synthetic Alt press+release after rofi grabs keyboard.
# If Alt was already released (quick-tap), rofi sees a press then release → !Alt_L fires → accept.
# If Alt is still physically held, wlroots merges key state across devices,
# so Alt stays pressed until the real physical release.
if command -v wtype >/dev/null 2>&1; then
  (
    sleep 0.3
    kill -0 "${ROFI_PID}" 2>/dev/null || exit 0
    wtype -P Alt_L -s 30 -p Alt_L 2>/dev/null || true
  ) &
  WATCH_PID=$!
fi

wait "${ROFI_PID}" || true
[[ -n "${WATCH_PID:-}" ]] && { kill "${WATCH_PID}" 2>/dev/null; wait "${WATCH_PID}" 2>/dev/null; } || true

selected_name="$(<"${_rofi_out}")"
[[ -z "${selected_name}" ]] && exit 0

selected_id="$(echo "${ws_json}" | jq -r --arg name "${selected_name}" \
  '.[] | select(.name == $name) | .id' | head -n 1)"
[[ -z "${selected_id}" || "${selected_id}" == "null" ]] && exit 0

hyprctl dispatch focusworkspaceoncurrentmonitor "${selected_id}" >/dev/null 2>&1 || true
prepend_mru_atomic "${CACHE_DIR}" "${selected_id}"
