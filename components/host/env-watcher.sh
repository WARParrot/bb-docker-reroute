#!/usr/bin/env bash
# bb-docker-route host-side env watcher (run on the HOST, not in the sandbox).
#
# Solves two boundary problems between bb (host) and docker sandboxes:
#
# 1. DIR VISIBILITY: bb env dirs (/root/.bb/personal-workspaces/env_<id>) are
#    created host-side and are invisible inside sandbox containers whose /root
#    is a bind-mount of a sandbox home. -> Every env dir is mirrored into every
#    sandbox home.
#
# 2. FILE VISIBILITY (v2.4): files an agent writes INSIDE a container land in
#    the sandbox home (shadow copy), which bb does not read; files bb writes
#    land host-side, which the agent does not see. -> Both copies are synced
#    bidirectionally (cp -au, newer mtime wins per file; deletions do NOT
#    propagate — safe for session-scoped dirs). Shadow-only env dirs (created
#    by the agent's cd-shim before bb ever made one) are backfilled to the
#    host so bb sees the agent's files.
#
# Sandbox home layouts (both matched, mirrors get-bb/bb nesting fix b6f98b0):
#   …/sandboxes/<name>/home            (1 level)
#   …/sandboxes/<backend>/<name>/home  (2 levels, e.g. docker/default)
# The .bb/personal-workspaces path is built by the watcher, so fresh homes
# without .bb work (no chicken-and-egg).
#
# Usage: env-watcher.sh [host-env-dir] [homes-glob ...]
#   Globs match SANDBOX HOMES (…/home). Default: both known depths.
#
# Zero deps: pure bash + cp. Polling every BDR_SYNC_INTERVAL seconds.
# Safety: writes ONLY under sandbox homes matching */sandboxes/*[/]*/home.
set -u
SRC="${1:-$HOME/.bb/personal-workspaces}"
shift || true
if [ "$#" -gt 0 ]; then
  HOMES_GLOBS=("$@")
else
  HOMES_GLOBS=("${HOME}/.hermes/sandboxes/*/home" "${HOME}/.hermes/sandboxes/*/*/home")
fi
SYNC_INTERVAL="${BDR_SYNC_INTERVAL:-5}"

mkdir -p "$SRC"
log() { printf '[bb-docker-route host] %s\n' "$*" >&2; }

# Hard guard: sandbox homes are …/sandboxes/<x>/home or …/sandboxes/<x>/<y>/home
# ONLY (even when the caller overrides the globs).
is_sandbox_home() {
  case "$1" in
    */sandboxes/*/home|*/sandboxes/*/*/home) [ -d "$1" ] ;;
    *) return 1 ;;
  esac
}

sync_pair() {  # bidirectional content sync, newer mtime wins, no deletions
  local host_dir="$1" shadow_dir="$2"
  mkdir -p "$host_dir" "$shadow_dir"
  cp -au "$host_dir/." "$shadow_dir/" 2>/dev/null
  cp -au "$shadow_dir/." "$host_dir/" 2>/dev/null
}

sync_all() {
  local glob home pw d base shadow
  for glob in "${HOMES_GLOBS[@]}"; do
    for home in $glob; do
      is_sandbox_home "$home" || continue
      pw="${home}/.bb/personal-workspaces"
      # host -> shadow: bb-created env dirs appear inside the container
      for d in "$SRC"/env_*; do
        [ -d "$d" ] || continue
        sync_pair "$d" "${pw}/$(basename "$d")"
      done
      # shadow -> host: agent-born env dirs become visible to bb, then sync
      for shadow in "$pw"/env_*; do
        [ -d "$shadow" ] || continue
        base="$(basename "$shadow")"
        [ -d "${SRC}/${base}" ] || log "backfilled ${base} -> host"
        sync_pair "${SRC}/${base}" "$shadow"
      done
    done
  done
}

sync_all
log "initial sync done (src=${SRC}); polling every ${SYNC_INTERVAL}s"
while sleep "$SYNC_INTERVAL"; do sync_all; done
