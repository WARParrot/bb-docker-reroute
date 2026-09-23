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
TH="$(mktemp -d)"
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

echo "# remove"
bash "$TH/.bb-docker-route/bin/bb-docker-route" remove >/dev/null 2>&1
check "$(grep -cF 'bb-docker-route' "$TH/.bashrc")" 0 "bashrc fully cleaned"
[ ! -e "$TH/.bb-docker-route" ] && ok "state dir removed" || bad "state dir still present"

rm -rf "$TH"
echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" = 0 ]
