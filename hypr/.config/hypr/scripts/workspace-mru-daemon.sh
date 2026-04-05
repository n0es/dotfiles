#!/usr/bin/env bash
# Track workspace focus order (MRU) for workspace-alt-tab.sh.
# Uses only workspacev2 (Hyprland ≥0.37): the legacy workspace>> event
# can also fire on the same switch and duplicate prepend_mru with wrong order.

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=workspace-mru-lib.sh
source "${_script_dir}/workspace-mru-lib.sh"

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/hypr"
mkdir -p "${cache_dir}"

: "${HYPRLAND_INSTANCE_SIGNATURE:?Run under Hyprland (HYPRLAND_INSTANCE_SIGNATURE unset)}"
socket="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"

seed_active() {
  local id
  id="$(hyprctl -j activeworkspace 2>/dev/null | jq -r '.id // empty')" || id=""
  [[ -n "${id}" ]] && prepend_mru_atomic "${cache_dir}" "${id}"
}

handle_line() {
  local line="$1"
  line="${line//$'\r'/}"

  case "${line}" in
    workspacev2\>\>*)
      local data id
      data="${line#workspacev2>>}"
      id="${data%%,*}"
      id="${id#"${id%%[![:space:]]*}"}"
      id="${id%"${id##*[![:space:]]}"}"
      prepend_mru_atomic "${cache_dir}" "${id}"
      ;;
  esac
}

if ! command -v socat >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

seed_active

socat -U - "UNIX-CONNECT:${socket}" | while IFS= read -r line; do
  handle_line "${line}" || true
done
