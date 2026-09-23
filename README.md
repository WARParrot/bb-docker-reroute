# bb-docker-route

Container-first routing for bb sessions. bb runs host-side; a docker sandbox
bind-mounts `/root` from the host, so bb's env dirs
(`~/.bb/personal-workspaces/env_<id>`) exist host-side only — every container
shell used to die on start with `cd: No such file or directory` (exit 126),
bb-listed skills pointed at host-only paths, and the bb CLI was unreachable.

This plugin makes the container side self-healing, with **zero manual steps
after the first install**.

## Zero-touch guarantees

- Every new shell auto-provisions missing bb env dirs before anything cd's.
- A self-healing `cd` (exported to children too) creates a missing env dir and
  retries; all other paths keep genuine error semantics.
- If the installed copy is ever wiped (sandbox rebuild), the next shell
  silently restores it: **local checkout → git clone** (public repo, no
  creds needed). A zip copy is also kept on the host (Wiki project
  `bb-docker-route`) as an offline artifact.
- Idempotent installer; reversible with one command (`remove`).
- Hermetic test battery (`tests/run-tests.sh`, throwaway HOME) runs in CI.

## Install (once, inside the container)

```bash
# from a checkout
bash bin/bb-docker-route install
# or straight from git once the repo exists
bash <(git clone --depth 1 https://github.com/WARParrot/bb-docker-route.git -o /tmp/bdr && cat /tmp/bdr/bin/bb-docker-route)
```

New shells pick everything up automatically; verify with:

```bash
bb-docker-route doctor     # components + restore chain
bb-docker-route status     # JSON probe
```

## Repository layout

| Path | Role |
|------|------|
| `bin/bb-docker-route` | CLI: `provision`, `status`, `doctor`, `install`, `remove` |
| `components/install.sh` | Idempotent installer (marked `~/.bashrc` blocks, PATH symlink) |
| `components/rc.sh` | Exports + self-healing `cd` + DEBUG-trap shim |
| `components/hook.sh` | Pre-cd safety net (scans `/proc/*/cwd`) |
| `components/probe-container-tool.sh` | JSON probe for routing decisions |
| `components/host/env-watcher.sh` | HOST-side: mirrors env dirs into sandbox homes (covers non-bash tools) |
| `bootstrap.sh` | Restore chain: local checkout → git clone (public repo) |
| `tests/run-tests.sh` | Hermetic battery (throwaway HOME, no system writes) |

## Host-side permanent fix (optional, complements the plugin)

```bash
mkdir -p /root/.hermes/sandboxes/docker/default/home/.bb/personal-workspaces/env_<id>
```

## Removal

```bash
bb-docker-route remove
```
