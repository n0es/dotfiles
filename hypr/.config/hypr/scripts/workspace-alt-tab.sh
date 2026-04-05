#!/usr/bin/env bash
# Workspace Alt+Tab session controller.
# - start next|prev: start session on monitor under cursor and select item
# - cycle next|prev: move selection in current session
# - apply: switch to selected workspace, clear UI/session
# - cancel: clear UI/session only

set -euo pipefail

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/hypr"
STATE_FILE="${STATE_DIR}/workspace_alt_tab_state.json"
MRU_FILE="${STATE_DIR}/workspace_mru"
mkdir -p "${STATE_DIR}"

NOTIFY_ICON="1"
NOTIFY_TIME="12000"
NOTIFY_COLOR="0"

action="${1:-}"
direction="${2:-next}"

require_tools() {
  command -v hyprctl >/dev/null 2>&1 || exit 1
  command -v jq >/dev/null 2>&1 || exit 1
}

dismiss_ui() {
  hyprctl dismissnotify 20 >/dev/null 2>&1 || true
}

show_notification() {
  local text="$1"
  if ! hyprctl notify "${NOTIFY_ICON}" "${NOTIFY_TIME}" "${NOTIFY_COLOR}" "${text}" >/dev/null 2>&1; then
    if command -v notify-send >/dev/null 2>&1; then
      notify-send "Workspace switcher" "${text}" >/dev/null 2>&1 || true
    fi
  fi
}

get_monitor_under_cursor() {
  local monitors cursor_raw cx cy monitor
  monitors="$(hyprctl -j monitors all 2>/dev/null || hyprctl -j monitors 2>/dev/null || echo '[]')"
  cursor_raw="$(hyprctl -j cursorpos 2>/dev/null || echo '{}')"

  cx="$(echo "${cursor_raw}" | jq -r '.x // empty' 2>/dev/null || true)"
  cy="$(echo "${cursor_raw}" | jq -r '.y // empty' 2>/dev/null || true)"

  if [[ -n "${cx}" && -n "${cy}" ]]; then
    monitor="$(
      echo "${monitors}" | jq -r --argjson x "${cx}" --argjson y "${cy}" '
        .[]
        | select($x >= .x and $x < (.x + .width) and $y >= .y and $y < (.y + .height))
        | .name
      ' 2>/dev/null | head -n 1
    )"
    if [[ -n "${monitor}" ]]; then
      printf '%s\n' "${monitor}"
      return 0
    fi
  fi

  echo "${monitors}" | jq -r '.[] | select(.focused == true) | .name' | head -n 1
}

load_monitor_workspaces() {
  local monitor="$1"
  local ws_json
  ws_json="$(hyprctl -j workspaces 2>/dev/null || echo '[]')"
  echo "${ws_json}" | jq -c --arg mon "${monitor}" '
    [ .[]
      | select(.monitor == $mon and (.id // 0) > 0)
      | { id, name }
    ] | sort_by(.id)
  '
}

order_ids_with_mru() {
  local ws_array_json="$1"
  local -n out_ids_ref="$2"
  local -n out_names_ref="$3"
  local id name line
  local -a ids_sorted=()
  local -a ordered_ids_local=()
  declare -A names_by_id=()
  declare -A seen=()

  while IFS=$'\t' read -r id name; do
    [[ -z "${id}" ]] && continue
    ids_sorted+=("${id}")
    names_by_id["${id}"]="${name}"
  done < <(echo "${ws_array_json}" | jq -r '.[] | "\(.id)\t\(.name)"')

  if [[ -f "${MRU_FILE}" ]]; then
    while IFS= read -r id; do
      [[ -z "${id}" ]] && continue
      if [[ -n "${names_by_id[${id}]+x}" && -z "${seen[${id}]+x}" ]]; then
        ordered_ids_local+=("${id}")
        seen["${id}"]=1
      fi
    done < "${MRU_FILE}"
  fi

  for id in "${ids_sorted[@]}"; do
    if [[ -z "${seen[${id}]+x}" ]]; then
      ordered_ids_local+=("${id}")
      seen["${id}"]=1
    fi
  done

  out_ids_ref=()
  out_names_ref=()
  for id in "${ordered_ids_local[@]}"; do
    out_ids_ref+=("${id}")
    out_names_ref+=("${names_by_id[${id}]}")
  done
}

active_workspace_id_for_monitor() {
  local monitor="$1"
  local monitors
  monitors="$(hyprctl -j monitors all 2>/dev/null || hyprctl -j monitors 2>/dev/null || echo '[]')"
  echo "${monitors}" | jq -r --arg mon "${monitor}" '.[] | select(.name == $mon) | .activeWorkspace.id' | head -n 1
}

write_state() {
  local monitor="$1"
  local ids_json="$2"
  local names_json="$3"
  local selected="$4"

  jq -n \
    --arg monitor "${monitor}" \
    --argjson ids "${ids_json}" \
    --argjson names "${names_json}" \
    --argjson selected "${selected}" \
    '{ monitor: $monitor, ids: $ids, names: $names, selected: $selected }' > "${STATE_FILE}"
}

show_state_ui() {
  local state monitor selected msg
  local -a lines=()
  local i count
  state="$(cat "${STATE_FILE}")"
  monitor="$(echo "${state}" | jq -r '.monitor')"
  selected="$(echo "${state}" | jq -r '.selected')"
  count="$(echo "${state}" | jq -r '.ids | length')"

  for (( i=0; i<count; i++ )); do
    local wid wname prefix
    wid="$(echo "${state}" | jq -r --argjson i "${i}" '.ids[$i]')"
    wname="$(echo "${state}" | jq -r --argjson i "${i}" '.names[$i]')"
    prefix="  "
    if [[ "${i}" -eq "${selected}" ]]; then
      prefix="> "
    fi
    lines+=("${prefix}${wid}: ${wname}")
  done

  dismiss_ui
  msg="$(printf 'Workspaces (%s)\n%s\n\nTab/Shift+Tab to cycle, release Alt to switch' "${monitor}" "$(printf '%s\n' "${lines[@]}")")"
  show_notification "${msg}"
}

read_state_or_exit() {
  [[ -f "${STATE_FILE}" ]] || exit 0
  jq -e '.ids | length > 0' "${STATE_FILE}" >/dev/null 2>&1 || exit 0
}

step_index() {
  local current="$1"
  local total="$2"
  local dir="$3"
  if [[ "${dir}" == "prev" ]]; then
    echo $(( (current - 1 + total) % total ))
  else
    echo $(( (current + 1) % total ))
  fi
}

start_session() {
  local dir="$1"
  local monitor ws_array_json active_id
  local -a ordered_ids=()
  local -a ordered_names=()
  local ids_json names_json count idx=-1 i initial

  monitor="$(get_monitor_under_cursor)"
  if [[ -z "${monitor}" ]]; then
    show_notification "Could not determine monitor for workspace switch."
    exit 0
  fi

  ws_array_json="$(load_monitor_workspaces "${monitor}")"
  order_ids_with_mru "${ws_array_json}" ordered_ids ordered_names

  count="${#ordered_ids[@]}"
  if [[ "${count}" -eq 0 ]]; then
    show_notification "No workspaces found on monitor ${monitor}."
    exit 0
  fi

  active_id="$(active_workspace_id_for_monitor "${monitor}")"
  for (( i=0; i<count; i++ )); do
    if [[ "${ordered_ids[$i]}" == "${active_id}" ]]; then
      idx="${i}"
      break
    fi
  done
  [[ "${idx}" -lt 0 ]] && idx=0

  initial="$(step_index "${idx}" "${count}" "${dir}")"
  ids_json="$(printf '%s\n' "${ordered_ids[@]}" | jq -R . | jq -s 'map(tonumber)')"
  names_json="$(printf '%s\n' "${ordered_names[@]}" | jq -R . | jq -s '.')"

  write_state "${monitor}" "${ids_json}" "${names_json}" "${initial}"
  show_state_ui
}

cycle_session() {
  local dir="$1"
  local count selected next

  read_state_or_exit
  count="$(jq -r '.ids | length' "${STATE_FILE}")"
  selected="$(jq -r '.selected' "${STATE_FILE}")"
  next="$(step_index "${selected}" "${count}" "${dir}")"
  tmp="$(mktemp)"
  jq --argjson s "${next}" '.selected = $s' "${STATE_FILE}" > "${tmp}"
  mv "${tmp}" "${STATE_FILE}"
  show_state_ui
}

apply_session() {
  local monitor selected_id

  read_state_or_exit
  monitor="$(jq -r '.monitor' "${STATE_FILE}")"
  selected_id="$(jq -r '.ids[.selected]' "${STATE_FILE}")"

  dismiss_ui
  hyprctl dispatch focusmonitor "${monitor}" >/dev/null 2>&1 || true
  hyprctl dispatch focusworkspaceoncurrentmonitor "${selected_id}" >/dev/null 2>&1 || true
  rm -f "${STATE_FILE}"
}

cancel_session() {
  dismiss_ui
  rm -f "${STATE_FILE}"
}

require_tools

case "${action}" in
  start)
    start_session "${direction}"
    ;;
  cycle)
    cycle_session "${direction}"
    ;;
  apply)
    apply_session
    ;;
  cancel)
    cancel_session
    ;;
  *)
    exit 1
    ;;
esac
