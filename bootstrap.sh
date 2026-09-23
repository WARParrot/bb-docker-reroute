#!/usr/bin/env bash
# bb-docker-route bootstrap: restore the installed plugin if it is missing.
# Chain: local checkout (recorded at install time) -> git clone (public repo).
# Called automatically from the ~/.bashrc auto-provision block.
set -uo pipefail
DEST="${HOME}/.bb-docker-route"
[ -x "${DEST}/bin/bb-docker-route" ] && exit 0   # healthy, nothing to do

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

restore_from_dir() {
  local src="$1"
  [ -f "${src}/components/install.sh" ] || return 1
  BB_DOCKER_ROUTE_NO_SYMLINK="${BB_DOCKER_ROUTE_NO_SYMLINK:-0}" \
    bash "${src}/components/install.sh" >/dev/null 2>&1
}

restore_from_git() {
  local repo="${BB_DOCKER_ROUTE_REPO:-https://github.com/WARParrot/bb-docker-reroute.git}"
  local tmp; tmp="$(mktemp -d)"
  if git clone --depth 1 "${repo}" "${tmp}/repo" >/dev/null 2>&1; then
    restore_from_dir "${tmp}/repo" && return 0
  fi
  rm -rf "${tmp}"; return 1
}

restore_from_dir "${SELF_DIR}/.." || restore_from_git || exit 0
