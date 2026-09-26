#!/usr/bin/env bash
# bb-docker-route host-side env-dir watcher (run on the HOST, not in the sandbox).
#
# Why: bind-mounted sandbox homes mean bb env dirs created host-side for host
# sessions never appear inside containers, and a container cannot create them
# for non-bash tools that cd before asking. This watcher mirrors any
# ~/.bb/personal-workspaces/env_* seen on the host into every active Hermes
# docker sandbox home, so containers always see the dir before first use.
#
# Zero external deps: pure bash + inotifywait if present, otherwise polling.
# Idempotent: skips dirs that already exist. No cron needed.
set -u
SRC="${1:-$HOME/.bb/personal-workspaces}"
SANDBOX_GLOB="${2:-/root/.hermes/sandboxes/*/home/.bb/personal-workspaces}"

mkdir -p "$SRC"
log() { printf '[bb-docker-route host] %s\n' "$*" >&2; }

mirror_once() {
  local d base tgt home_dir
  for d in "$SRC"/env_*; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    for tgt in $SANDBOX_GLOB; do
      # guard on the sandbox HOME level (…/home/.bb/personal-workspaces → …/home):
      # a fresh home may not have .bb yet — create the full path on demand.
      home_dir="$(dirname "$(dirname "$tgt")")"
      [ -d "$home_dir" ] || continue
      [ -d "${tgt}/${base}" ] || { mkdir -p "${tgt}/${base}" && log "mirrored ${base} -> ${tgt}"; }
    done
  done
}

mirror_once
log "initial mirror done; watching ${SRC}"
if command -v inotifywait >/dev/null 2>&1; then
  while read -r _; do mirror_once; done \
    < <(inotifywait -q -m -e create,moved_to --format '%w%f' "$SRC" 2>/dev/null)
else
  log "inotifywait absent; polling every 5s"
  while sleep 5; do mirror_once; done
fi
