#!/usr/bin/env bash
# Rofi picker for workspaces ordered by MRU from workspace-mru-daemon.sh.

set -euo pipefail

mru_file="${XDG_CACHE_HOME:-$HOME/.cache}/hypr/workspace_mru"

if ! command -v rofi >/dev/null 2>&1; then
  notify-send "workspace-mru-menu" "rofi not found in PATH"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  notify-send "workspace-mru-menu" "jq not found in PATH"
  exit 1
fi

ws_json="$(hyprctl workspaces -j 2>/dev/null)" || ws_json="[]"

mapfile -t mru_order < <(
  if [[ -f "${mru_file}" ]]; then
    grep -v '^[[:space:]]*$' "${mru_file}" || true
  fi
)

ordered_ids=()
seen_ids=()

has_id() {
  local id="$1"
  local item

  for item in "${seen_ids[@]:-}"; do
    [[ "${item}" == "${id}" ]] && return 0
  done
  return 1
}

is_live_workspace() {
  local id="$1"
  echo "${ws_json}" | jq -e --arg id "${id}" '.[] | select(.id == ($id | tonumber))' >/dev/null 2>&1
}

add_id() {
  local id="$1"
  [[ -z "${id}" ]] && return 0
  has_id "${id}" && return 0
  is_live_workspace "${id}" || return 0
  ordered_ids+=("${id}")
  seen_ids+=("${id}")
}

for id in "${mru_order[@]:-}"; do
  add_id "${id}"
done

while IFS= read -r id; do
  add_id "${id}"
done < <(echo "${ws_json}" | jq -r '.[].id | tostring' | sort -n)

if [[ ${#ordered_ids[@]} -eq 0 ]]; then
  notify-send "workspace-mru-menu" "No workspaces available"
  exit 0
fi

labels=()
for id in "${ordered_ids[@]}"; do
  name="$(echo "${ws_json}" | jq -r --arg id "${id}" '.[] | select(.id == ($id | tonumber)) | .name')"
  labels+=("${name} [${id}]")
done

idx="$(printf '%s\n' "${labels[@]}" | rofi -dmenu -i -p "Workspaces (MRU)" -format i -theme-str 'window { width: 40%; }')" || idx=""

[[ -z "${idx}" ]] && exit 0

pick="${ordered_ids[${idx}]}"
[[ -z "${pick}" ]] && exit 0

( sleep 0.08 && hyprctl dispatch workspace "${pick}" ) &
