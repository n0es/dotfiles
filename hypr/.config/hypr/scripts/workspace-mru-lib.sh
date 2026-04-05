# shellcheck shell=bash
# Shared MRU file update for workspace-alt-tab.sh and workspace-mru-daemon.sh.
# Uses flock so the daemon and Alt+Tab script cannot clobber each other.

prepend_mru_atomic() {
  local cache_dir="$1"
  local id="$2"
  local mru_file="${cache_dir}/workspace_mru"
  local lock="${cache_dir}/workspace_mru.lock"
  local rest=""

  id="${id//$'\r'/}"
  id="${id#"${id%%[![:space:]]*}"}"
  id="${id%"${id##*[![:space:]]}"}"

  [[ -z "${id}" ]] && return 0

  mkdir -p "${cache_dir}"

  if command -v flock >/dev/null 2>&1; then
    (
      flock 200
      rest=""
      if [[ -f "${mru_file}" ]]; then
        rest="$(grep -vxF "${id}" "${mru_file}" || true)"
        rest="${rest//$'\r'/}"
      fi
      {
        printf '%s\n' "${id}"
        printf '%s\n' "${rest}"
      } | awk 'NF { if (!seen[$0]++) print }' > "${mru_file}.tmp"
      mv "${mru_file}.tmp" "${mru_file}"
    ) 200>"${lock}"
  else
    rest=""
    if [[ -f "${mru_file}" ]]; then
      rest="$(grep -vxF "${id}" "${mru_file}" || true)"
      rest="${rest//$'\r'/}"
    fi
    {
      printf '%s\n' "${id}"
      printf '%s\n' "${rest}"
    } | awk 'NF { if (!seen[$0]++) print }' > "${mru_file}.tmp"
    mv "${mru_file}.tmp" "${mru_file}"
  fi
}
