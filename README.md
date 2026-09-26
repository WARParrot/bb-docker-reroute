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
| `package.json` | bb plugin manifest: `bb.server` entry, branding, skills |
| `server.ts` | bb server lifecycle entry (`export default function plugin(bb)`) |
| `skills/bb-docker-route/` | bb skill shipped with the plugin |
| `assets/icon.svg` | plugin branding icon |
| `bin/bb-docker-route` | CLI: `provision`, `status`, `doctor`, `install`, `remove` |
| `components/install.sh` | Idempotent installer (marked `~/.bashrc` blocks, PATH symlink) |
| `components/rc.sh` | Exports + self-healing `cd` + DEBUG-trap shim |
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

## Attachment mirroring (v2.3.0, zero-touch)

A `bb.background.service` ("attachment-mirror") lives inside the bb server on
the HOST and re-runs the mirror every 5s. Attach a file to a thread -> it
appears in every sandbox home within seconds, while bb runs, with no user
action. Algorithm stays in attachment-watcher.sh (hermetically tested, incl.
the service harness: start-pass, cadence, clean stop, no post-stop passes).
Manual paths still work: `bb-docker-route attachments once`, or the
long-running watcher below.

Sandbox layouts vary (sandboxes/<name>/home vs sandboxes/<backend>/<name>/home,
e.g. docker/default); the default glob matches both. After updating the plugin
NO bb restart is needed:

    bb plugin reload bb-docker-route

## Manual mirroring (v2.2.0, fallback)

bb stores thread attachments under `~/.bb/thread-storage/<thread>/Attachments`
**host-side only** — sandboxed agents cannot read them. The new host-side
component mirrors the whole tree into every sandbox home:

```bash
# on the HOST (once; long-running):
~/.bb-docker-route/components/host/attachment-watcher.sh          # watch mode
# or single pass (cron-friendly):
~/.bb-docker-route/components/host/attachment-watcher.sh once
```

Inside the container the same helper is reachable via
`bb-docker-route attachments [once] [src] [sandbox-glob]`.
`bb-docker-route status` reports `attachment_watcher`; `doctor` shows install state.
Additive and idempotent: never deletes sandbox files, re-copies only newer ones.
