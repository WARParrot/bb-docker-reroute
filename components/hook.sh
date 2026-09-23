#!/usr/bin/env bash
# bb-docker-route hook.sh — called by bb shell hooks (if supported) or manually.
# Ensures the env dir for the current session exists before any cd / exec.
set -u
ENV_ID="${1:-}"
DIR="${HOME}/.bb/personal-workspaces"
if [ -n "$ENV_ID" ]; then
  mkdir -p "${DIR}/env_${ENV_ID}"
else
  # Best-effort: create any env_* dir referenced by /proc/*/cwd of shells.
  for p in /proc/[0-9]*/cwd; do
    tgt="$(readlink -f "$p" 2>/dev/null)" || continue
    case "$tgt" in
      "${DIR}"/env_*) [ -d "$tgt" ] || mkdir -p "$tgt" 2>/dev/null ;;
    esac
  done
fi
exit 0
