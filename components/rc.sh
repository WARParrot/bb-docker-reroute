# bb-docker-route rc.sh — sourced by interactive shells (see installer).
# Container-first routing for bb sessions running inside a Docker env.
# Additive: does not touch bb defaults, only supplements them.

export BB_DOCKER_ROUTE=1

# Guard: child containers started from this shell must not re-run the
# auto-provision block from .bashrc (avoids recursion in nested shells).
export BB_BASH_ENV_BOOTSTRAP=1

# Non-interactive bash (e.g. `bash -lc`, docker exec bash -c) also gets the
# shim via BASH_ENV when this file is sourced early enough.
if [ -z "${BASH_ENV:-}" ]; then
  export BASH_ENV="${HOME}/.bb-docker-route/rc.sh"
fi

# Self-healing cd: if the target is a bb env dir that exists on the host but
# not in this container, create it and retry. Transparent for all other paths.
# Exported so non-interactive child shells (bash -c) inherit it too.
cd() {
  if builtin cd "$@" 2>/dev/null; then return 0; fi
  case "${1:-}" in
    */.bb/personal-workspaces/*|env_*)
      mkdir -p "${1/#\~/$HOME}" 2>/dev/null && builtin cd "$@" && return 0 ;;
  esac
  builtin cd "$@"   # not an env dir: surface the genuine error
}
export -f cd 2>/dev/null || true

# DEBUG-trap backup for shells that never cd but exec with a stale cwd.
__bb_route_shim() {
  local d="${HOME}/.bb/personal-workspaces"
  case "$PWD" in
    "$d"/*) [ -d "$PWD" ] || mkdir -p "$PWD" 2>/dev/null ;;
  esac
}
trap '__bb_route_shim' DEBUG
