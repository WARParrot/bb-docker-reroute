#!/usr/bin/env bash
# bb-docker-route probe: emits environment facts used for routing decisions.
# Exit code 0 always (informational); JSON on stdout.
set -u
j() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1" 2>/dev/null || echo '""'; }
in_docker() { grep -qE 'docker|containerd' /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ]; }
env_id="${BB_ENV_ID:-${BB_ENVIRONMENT_ID:-}}"
for f in "${HOME}/.bb/current-env" "${HOME}/.bb/env"; do
  [ -r "$f" ] && env_id="$(head -c 64 "$f" | tr -d '[:space:]')" && break
done
[ -z "$env_id" ] && env_id="$(basename "$(readlink -f /proc/$$/cwd 2>/dev/null)" 2>/dev/null)"
printf '{"in_docker":%s,"env_id":%s,"home_mount":"%s","bash_env":%s,"bb_on_path":%s}\n' \
  "$(in_docker && echo true || echo false)" \
  "$(j "$env_id")" \
  "$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/.*\[\(.*\)\]/\1/')" \
  "$(j "${BASH_ENV:-}")" \
  "$(command -v bb >/dev/null 2>&1 && echo true || echo false)"
