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

mkdir -p "${CACHE_DIR}" "${PREVIEW_DIR}"

exec 200>"${RUN_LOCK}"
flock -n 200 || exit 0

command -v hyprctl >/dev/null 2>&1 || exit 1
command -v jq >/dev/null 2>&1 || exit 1
command -v rofi >/dev/null 2>&1 || exit 1

[[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || {
  local_daemon="${SCRIPT_DIR}/workspace-mru-daemon.sh"
  [[ -f "${local_daemon}" ]] && ! pgrep -f "workspace-mru-daemon\.sh" >/dev/null 2>&1 && \
    "${local_daemon}" >/dev/null 2>&1 &
}

# --- Single jq call: all hyprctl data → flat text ---
_tmp_ws="$(mktemp)" _tmp_cl="$(mktemp)" _tmp_mon="$(mktemp)" _rofi_out="$(mktemp)"
trap 'rm -f "${_tmp_ws}" "${_tmp_cl}" "${_tmp_mon}" "${_rofi_out}"' EXIT
(hyprctl -j workspaces 2>/dev/null || echo '[]') > "${_tmp_ws}" &
(hyprctl -j clients 2>/dev/null || echo '[]') > "${_tmp_cl}" &
(hyprctl -j monitors 2>/dev/null || echo '[]') > "${_tmp_mon}" &
wait

data="$(jq -r -n \
  --slurpfile ws "${_tmp_ws}" \
  --slurpfile cl "${_tmp_cl}" \
  --slurpfile mon "${_tmp_mon}" '
  ($mon[0] | map(select(.focused)) | .[0] // {}) as $fm |
  ($mon[0] | [.[] | {(.name): {x:.x, y:.y}}] | add // {}) as $mpos |
  "\($fm.width // 1920)\t\($fm.height // 1080)\t\($fm.activeWorkspace.id // 0)",
  ([$ws[0][] | select(.id > 0)] | sort_by(.id)[] |
    . as $w |
    "\(.id)\t\(.name)\t\($mpos[.monitor].x // 0)\t\($mpos[.monitor].y // 0)\t\(
      [$cl[0][] | select(.workspace.id == $w.id and .mapped and (.hidden | not))
       | "\(.at[0]),\(.at[1]),\(.size[0]),\(.size[1])"] | join(";")
    )"
  )
')"

declare -A ws_names=() ws_mx=() ws_my=() ws_rects=()
all_ids=()
{
  IFS=$'\t' read -r mon_w mon_h active_id
  while IFS=$'\t' read -r ws_id ws_name mx my rects_str; do
    [[ -z "${ws_id}" ]] && continue
    all_ids+=("${ws_id}")
    ws_names["${ws_id}"]="${ws_name}"
    ws_mx["${ws_id}"]="${mx}"
    ws_my["${ws_id}"]="${my}"
    ws_rects["${ws_id}"]="${rects_str}"
  done
} <<< "${data}"

(( ${#all_ids[@]} <= 1 )) && exit 0
PREVIEW_H=$(( PREVIEW_W * mon_h / mon_w ))

# --- MRU ordering ---
active_id="${active_id//$'\r'/}"
[[ "${active_id}" == "0" || "${active_id}" == "null" ]] && active_id=""

if [[ -n "${active_id}" && -f "${MRU_FILE}" ]]; then
  first_in_mru="$(head -n1 "${MRU_FILE}" 2>/dev/null | tr -d '\r ' || true)"
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
    id="${id//$'\r'/}"; id="${id// /}"
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

# --- Preview generation (no jq — pure bash rect parsing) ---
MAGICK=""
command -v magick >/dev/null 2>&1 && MAGICK="magick"
[[ -z "${MAGICK}" ]] && command -v convert >/dev/null 2>&1 && MAGICK="convert"

_gen_preview() {
  local ws_id="$1" rects_str="$2" mx="$3" my="$4"
  local pp="${PREVIEW_DIR}/ws_${ws_id}.png" sp="${PREVIEW_DIR}/ws_${ws_id}.sig"
  [[ -z "${MAGICK}" ]] && return 0

  local sig="${rects_str}|${mx}|${my}|${mon_w}|${mon_h}|${PREVIEW_W}"
  [[ -f "${pp}" && -f "${sp}" && "$(<"${sp}")" == "${sig}" ]] && return 0

  local -a draw_cmds=()
  if [[ -n "${rects_str}" ]]; then
    local rect wx wy ww wh rx1 ry1 rx2 ry2
    IFS=';' read -ra rect_list <<< "${rects_str}"
    for rect in "${rect_list[@]}"; do
      IFS=',' read -r wx wy ww wh <<< "${rect}"
      wx=$(( wx - mx )); wy=$(( wy - my ))
      rx1=$(( wx * PREVIEW_W / mon_w + 2 )); ry1=$(( wy * PREVIEW_H / mon_h + 2 ))
      rx2=$(( (wx + ww) * PREVIEW_W / mon_w + 2 )); ry2=$(( (wy + wh) * PREVIEW_H / mon_h + 2 ))
      (( rx1 < 2 )) && rx1=2; (( ry1 < 2 )) && ry1=2
      (( rx2 >= PREVIEW_W - 2 )) && rx2=$(( PREVIEW_W - 3 ))
      (( ry2 >= PREVIEW_H - 2 )) && ry2=$(( PREVIEW_H - 3 ))
      draw_cmds+=(-fill "#3d4555" -stroke "#5e6779" -strokewidth 1 \
        -draw "rectangle ${rx1},${ry1} ${rx2},${ry2}")
    done
  fi

  if "${MAGICK}" -size "${PREVIEW_W}x${PREVIEW_H}" "xc:#1a1b26" \
      -define png:compression-level=1 \
      -fill "#22232e" -stroke "#3a3d4e" -strokewidth 1 \
      -draw "roundrectangle 1,1 $(( PREVIEW_W-2 )),$(( PREVIEW_H-2 )) 4,4" \
      ${draw_cmds[@]+"${draw_cmds[@]}"} \
      -gravity center -pointsize 32 -fill "#ffffff40" -annotate 0 "${ws_id}" \
      "${pp}" 2>/dev/null; then
    printf '%s' "${sig}" > "${sp}"
  fi
}

for id in "${ordered_ids[@]}"; do
  _gen_preview "${id}" "${ws_rects[${id}]:-}" "${ws_mx[${id}]:-0}" "${ws_my[${id}]:-0}" &
done
wait

# --- Build rofi input + launch ---
num_ws="${#ordered_ids[@]}"
columns="${MAX_COLUMNS}"
(( num_ws < columns )) && columns="${num_ws}"
lines=$(( (num_ws + columns - 1) / columns ))

(
  for id in "${ordered_ids[@]}"; do
    name="${ws_names[${id}]:-${id}}"
    preview="${PREVIEW_DIR}/ws_${id}.png"
    if [[ -f "${preview}" ]]; then
      printf '%s\0icon\x1f%s\n' "${name}" "${preview}"
    else
      printf '%s\n' "${name}"
    fi
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
) > "${_rofi_out}" &
ROFI_PID=$!

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

# --- Find workspace ID by name and dispatch ---
selected_id=""
for id in "${ordered_ids[@]}"; do
  if [[ "${ws_names[${id}]:-}" == "${selected_name}" ]]; then
    selected_id="${id}"
    break
  fi
done
[[ -z "${selected_id}" ]] && exit 0

hyprctl dispatch focusworkspaceoncurrentmonitor "${selected_id}" >/dev/null 2>&1 || true
prepend_mru_atomic "${CACHE_DIR}" "${selected_id}"
