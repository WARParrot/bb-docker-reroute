#!/usr/bin/env bash
# bb-docker-route: interactive installer for a container-first bb shell session.
# Run inside the bb Docker environment container (or any sandboxed shell).
#
# Guarantees:
#   - additive: bb defaults untouched; marked blocks in ~/.bashrc only
#   - idempotent: re-running repairs/upgrades; never duplicates blocks
#   - reversible: `bb-docker-route remove`
#   - self-restoring: ~/.bashrc calls bootstrap.sh, which reinstalls from
#     local checkout -> git -> wiki mirror if the install is ever wiped
set -euo pipefail

BC_DIR="${HOME}/.bb-docker-route"
BC_RC="${BC_DIR}/rc.sh"
BC_BIN="${BC_DIR}/bin/bb-docker-route"
BC_SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SRC_DIR="$(dirname "${BC_SELF}")"
TOP_DIR="$(dirname "${SRC_DIR}")"

log() { printf '[bb-docker-route] %s\n' "$*"; }

mkdir -p "${BC_DIR}/bin" "${HOME}/.bb/personal-workspaces"
install -m 0755 "${TOP_DIR}/bin/bb-docker-route" "${BC_BIN}"
cp "${TOP_DIR}/components/hook.sh" "${BC_DIR}/hook.sh"
cp "${TOP_DIR}/components/rc.sh" "${BC_DIR}/rc.sh"
install -m 0755 "${TOP_DIR}/components/probe-container-tool.sh" "${BC_DIR}/probe-container-tool.sh"
install -m 0755 "${TOP_DIR}/bootstrap.sh" "${BC_DIR}/bootstrap.sh"
# remember where the checkout lives for offline restore
printf '%s\n' "${TOP_DIR}" > "${BC_DIR}/.checkout-path"

# Put the CLI on PATH so the .bashrc auto-provision block can call it.
if [ "${BB_DOCKER_ROUTE_NO_SYMLINK:-0}" != "1" ] && [ -w /usr/local/bin ] && [ ! -e /usr/local/bin/bb-docker-route ]; then
  ln -sf "${BC_BIN}" /usr/local/bin/bb-docker-route
fi

# ---------------------------------------------------------------- bashrc ----
# Always refresh our marked blocks (upgrade-safe): delete ranges, re-append.
sed -i '/# >>> bb-docker-route auto-provision >>>/,/# <<< bb-docker-route auto-provision <<</d' ~/.bashrc 2>/dev/null || true
sed -i '/# >>> bb-docker-route rc >>>/,/# <<< bb-docker-route rc <<</d' ~/.bashrc 2>/dev/null || true

# A) Automatic provisioning + self-restore (runs for every new shell).
cat >> ~/.bashrc <<BDRBLOCK
# >>> bb-docker-route auto-provision >>>
# bb-docker-route: restore plugin if wiped, then create missing bb env dirs.
if [ -z "\${BB_BASH_ENV_BOOTSTRAP:-}" ]; then
  [ -x "${BC_DIR}/bootstrap.sh" ] && "${BC_DIR}/bootstrap.sh" >/dev/null 2>&1
  command -v bb-docker-route >/dev/null 2>&1 && bb-docker-route provision >/dev/null 2>&1
fi
# <<< bb-docker-route auto-provision <<<
BDRBLOCK
log "bashrc: refreshed auto-provision + self-restore block"

# B) Interactive fast path (exports + self-healing cd + DEBUG shim).
cat >> ~/.bashrc <<BDRBLOCK
# >>> bb-docker-route rc >>>
[ -f "${BC_RC}" ] && . "${BC_RC}"
# <<< bb-docker-route rc <<<
BDRBLOCK
log "bashrc: refreshed rc source line"

log "done. Shells self-heal missing env dirs; install self-restores if wiped."
log "Status: bb-docker-route status | Checks: bb-docker-route doctor"
log "Remove anytime with: bb-docker-route remove"
