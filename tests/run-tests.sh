#!/usr/bin/env bash
# bb-docker-route test battery (hermetic: runs against a throwaway HOME).
# Note: /tmp is noexec here, so scripts are invoked via `bash <file>`.
set -uo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."
ROOT="$(pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok  - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
check(){ [ "$1" = "$2" ] && ok "$3" || bad "$3 (want '$2', got '$1')"; }

BDR_HAD_SYMLINK=0; [ -e /usr/local/bin/bb-docker-route ] && BDR_HAD_SYMLINK=1
# Prefer an ext4 home (this sandbox's /tmp is noexec+flaky); fall back to
# system tmp (CI runners: /tmp is exec-safe, /root not writable).
TH="$(mktemp -d /root/bdr-test-XXXXXX 2>/dev/null || mktemp -d)"
export HOME="$TH"
export BB_DOCKER_ROUTE_NO_SYMLINK=1   # never touch real /usr/local/bin in tests

echo "# bash syntax"
for f in bin/bb-docker-route components/*.sh components/host/*.sh bootstrap.sh tests/run-tests.sh; do
  bash -n "$f" && ok "syntax $f" || bad "syntax $f"
done

echo "# install + idempotency"
bash components/install.sh >/dev/null 2>&1 && ok "installer exits 0" || bad "installer exit"
bash components/install.sh >/dev/null 2>&1
check "$(grep -cF 'bb-docker-route auto-provision >>>' "$TH/.bashrc")" 1 "one auto-provision block"
check "$(grep -cF 'bb-docker-route rc >>>' "$TH/.bashrc")" 1 "one rc block"
check "$(ls "$TH/.bb-docker-route/rc.sh" >/dev/null 2>&1 && echo y)" y "rc.sh installed"
if [ -e /usr/local/bin/bb-docker-route ] && [ "${BDR_HAD_SYMLINK:-0}" = "0" ]; then
  bad "symlink leaked in hermetic mode"
else
  ok "no new symlink created (NO_SYMLINK)"
fi

echo "# stale-file pruning on reinstall"
touch "$TH/.bb-docker-route/hook.sh" "$TH/.bb-docker-route/probe-container-tool.sh"
bash components/install.sh >/dev/null 2>&1
[ ! -e "$TH/.bb-docker-route/hook.sh" ] && [ ! -e "$TH/.bb-docker-route/probe-container-tool.sh" ] \
  && ok "obsolete files pruned on reinstall" || bad "stale files not pruned"

echo "# interactive shell self-heal"
M="$TH/.bb/personal-workspaces/env_testid"
rm -rf "$M"
out="$(bash -ic "cd $M && pwd" 2>/dev/null | tail -1)"
check "$out" "$M" "interactive cd creates+enters missing env dir"

echo "# non-interactive via BASH_ENV / rc.sh"
rm -rf "$M"
out="$(BASH_ENV="$TH/.bb-docker-route/rc.sh" bash -c "cd $M && echo in" 2>/dev/null)"
[ "$out" = "in" ] && ok "BASH_ENV child heals too" || bad "BASH_ENV child (got '$out')"
rm -rf "$M"
out="$(env -i HOME="$TH" bash --noprofile --norc -c ". $TH/.bb-docker-route/rc.sh; cd $M && echo in" 2>/dev/null)"
[ "$out" = "in" ] && ok "bare bash + rc.sh heals" || bad "bare bash heal (got '$out')"

echo "# exports propagate"
out="$(bash -ic 'echo "$BB_DOCKER_ROUTE:$BB_BASH_ENV_BOOTSTRAP"' 2>/dev/null | tail -1)"
check "$out" "1:1" "child shell sees BB_DOCKER_ROUTE + BB_BASH_ENV_BOOTSTRAP"

echo "# normal cd semantics untouched"
out="$(bash -ic 'cd /tmp && echo tmp-ok' 2>/dev/null | tail -1)"
check "$out" "tmp-ok" "cd to existing dir works"
err="$(env -i HOME="$TH" bash --noprofile --norc -c ". $TH/.bb-docker-route/rc.sh; cd /definitely/not/here" 2>&1)"
case "$err" in
  *"/definitely/not/here: No such file or directory"*) ok "foreign path error preserved" ;;
  *) bad "foreign path error (got: $err)" ;;
esac

echo "# provision / status"
out="$(BB_ENV_ID=cafe1234 bash "$TH/.bb-docker-route/bin/bb-docker-route" provision 2>/dev/null)"
case "$out" in *env_cafe1234*) ok "provision explicit id" ;; *) bad "provision ($out)" ;; esac
st="$(BB_ENV_ID=cafe1234 bash "$TH/.bb-docker-route/bin/bb-docker-route" status 2>/dev/null)"
case "$st" in *'"env_dir_exists":true'*) ok "status reports existing dir" ;; *) bad "status ($st)" ;; esac

echo "# doctor"
doc="$(bash "$TH/.bb-docker-route/bin/bb-docker-route" doctor 2>/dev/null)"
case "$doc" in *"present"*) ok "doctor reports components" ;; *) bad "doctor" ;; esac

echo "# host env-watcher: fresh sandbox home (no .bb yet)"
WSRC="$TH/hostbb/.bb/personal-workspaces"; WHOME="$TH/sbhome"
mkdir -p "$WSRC/env_fresh" "$WHOME"   # Hermes provisions the home; watcher adds .bb tree
timeout 1 bash components/host/env-watcher.sh "$WSRC" "$WHOME/.bb/personal-workspaces" >/dev/null 2>&1
[ -d "$WHOME/.bb/personal-workspaces/env_fresh" ] && ok "watcher creates into fresh home" || bad "watcher fresh-home mirror"
FAKE="$TH/fake-host"
mkdir -p "$FAKE"
timeout 1 bash components/host/env-watcher.sh "$WSRC" "$FAKE/home/.bb/personal-workspaces" >/dev/null 2>&1
[ -e "$FAKE/home" ] && bad "watcher wrote into non-sandbox path" || ok "watcher refuses non-sandbox target"

echo "# attachment watcher: full-tree mirror into fresh sandbox home"
ASRC="$TH/hostbb/.bb/thread-storage"; AHOME="$TH/abhome"
mkdir -p "$ASRC/thr1/Attachments" "$ASRC/thr2/notes" "$AHOME"
printf 'payload' > "$ASRC/thr1/Attachments/task.7z"
printf 'nested' > "$ASRC/thr2/notes/readme.md"
timeout 1 bash components/host/attachment-watcher.sh once "$ASRC" "$AHOME/.bb/thread-storage" >/dev/null 2>&1
check "$(cat "$AHOME/.bb/thread-storage/thr1/Attachments/task.7z" 2>/dev/null)" payload "attachment mirrored (incl. nested dirs)"
if [ ! -e "$AHOME/.bb/thread-storage/thr2/notes/readme.md" ]; then bad "second thread not mirrored"; else ok "all threads mirrored"; fi
printf 'v2' > "$ASRC/thr1/Attachments/task.7z"
timeout 1 bash components/host/attachment-watcher.sh once "$ASRC" "$AHOME/.bb/thread-storage" >/dev/null 2>&1
check "$(cat "$AHOME/.bb/thread-storage/thr1/Attachments/task.7z")" v2 "re-mirror picks up changed files"
AF="$TH/afake"; mkdir -p "$AF"
timeout 1 bash components/host/attachment-watcher.sh once "$ASRC" "$AF/home/.bb/thread-storage" >/dev/null 2>&1
[ -e "$AF/home" ] && bad "attachment watcher wrote into non-sandbox path" || ok "attachment watcher refuses non-sandbox target"
out="$(BB_DOCKER_ROUTE=1 bash "$TH/.bb-docker-route/bin/bb-docker-route" attachments once "$ASRC" "$AHOME/.bb/thread-storage" 2>/dev/null)"
check "$(cat "$AHOME/.bb/thread-storage/thr1/Attachments/task.7z")" v2 "CLI 'attachments once' mirrors"

echo "# self-restore after wipe (bashrc block is the restorer)"
rm -rf "$TH/.bb-docker-route"
bash -ic 'echo x' >/dev/null 2>&1
[ -x "$TH/.bb-docker-route/bin/bb-docker-route" ] && ok "wiped install self-restored on next shell" || bad "self-restore after wipe"

echo "# remove"
bash "$TH/.bb-docker-route/bin/bb-docker-route" remove >/dev/null 2>&1
check "$(grep -cF 'bb-docker-route' "$TH/.bashrc")" 0 "bashrc fully cleaned"
[ ! -e "$TH/.bb-docker-route" ] && ok "state dir removed" || bad "state dir still present"

rm -rf "$TH"
echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" = 0 ]
