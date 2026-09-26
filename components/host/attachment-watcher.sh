#!/usr/bin/env bash
# bb-docker-route host-side attachment watcher (run on the HOST, not in the sandbox).
#
# Why: bb stores per-thread attachments under ~/.bb/thread-storage/<thread-id>/Attachments
# host-side only. Hermes docker sandboxes bind-mount a separate HOME
# (~/.hermes/sandboxes/<name>/home), so files attached to a bb thread never appear
# inside the container: reads fail with "No such file or directory". This watcher
# mirrors the whole thread-storage tree into every active sandbox home so agents
# can open attachments in-container.
#
# Usage:
#   attachment-watcher.sh [src] [sandbox-glob]        watch loop (default)
#   attachment-watcher.sh once [src] [sandbox-glob]   single mirror pass (tests/cron)
#
# Zero external deps; uses rsync when present, falls back to cp -p.
# Idempotent: existing identical files are not rewritten; additive (never deletes).
set -u
shopt -s nullglob   # unmatched glob -> empty loop, never a literal '*' path

MODE="watch"
if [ "${1:-}" = "once" ]; then MODE="once"; shift; fi
SRC="${1:-${HOME}/.bb/thread-storage}"
# Optional explicit target glob (thread-storage level, as in the tests).
# Default: every sandbox home's .bb dir -- it exists before thread-storage
# does, so first-run mirroring has a real anchor (no chicken-and-egg).
SANDBOX_GLOB="${2:-}"

log() { printf '[bb-docker-route host] %s\n' "$*" >&2; }

sync_tree() {
  local s="$1" d="$2" rel
  mkdir -p "$d"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$s/" "$d/" >/dev/null 2>&1
  else
    while IFS= read -r rel; do mkdir -p "$d/${rel#./}"; done < <(cd "$s" && find . -type d)
    while IFS= read -r rel; do
      rel="${rel#./}"
      if [ ! -f "$d/$rel" ] || [ "$s/$rel" -nt "$d/$rel" ]; then
        mkdir -p "$(dirname "$d/$rel")" && cp -p "$s/$rel" "$d/$rel"
      fi
    done < <(cd "$s" && find . -type f)
  fi
  return 0
}

mirror_once() {
  if [ ! -d "$SRC" ]; then
    log "no thread storage at $SRC (nothing attached yet)"
    return 1
  fi
  local tgt home_dir n=0 bbdir
  if [ -n "$SANDBOX_GLOB" ]; then
    for tgt in $SANDBOX_GLOB; do
      # guard on the sandbox HOME level (.../home/.bb/thread-storage -> .../home):
      # a fresh home may lack .bb -- create the full path on demand.
      home_dir="$(dirname "$(dirname "$tgt")")"
      [ -d "$home_dir" ] || continue
      sync_tree "$SRC" "$tgt"
      n=$((n+1))
    done
  else
    # Anchor at the sandbox home level: it exists as soon as the sandbox
    # does, so first-run mirroring has a real target (no chicken-and-egg);
    # .bb/thread-storage is created on demand inside it.
    # Layouts differ: sandboxes/<name>/home (1 level) or
    # sandboxes/<backend>/<name>/home (2 levels, e.g. docker/default).
    for home_dir in "${HOME}"/.hermes/sandboxes/*/home "${HOME}"/.hermes/sandboxes/*/*/home; do
      [ -d "$home_dir" ] || continue
      sync_tree "$SRC" "$home_dir/.bb/thread-storage"
      n=$((n+1))
    done
  fi
  if [ "$n" -gt 0 ]; then
    log "mirrored attachments from $SRC into $n sandbox home(s)"
    return 0
  fi
  log "no sandbox homes matched yet (waiting)"
  return 1
}

if [ "$MODE" = "once" ]; then
  mirror_once
  exit $?
fi

log "watching $SRC -> $SANDBOX_GLOB (polling every 5s)"
mirror_once || true
while sleep 5; do mirror_once || true; done
