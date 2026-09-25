---
name: bb-docker-route
description: Use when bb sessions or shells fail inside docker sandbox containers.
---

# bb-docker-route

Container-first routing for bb sessions running inside docker sandbox
containers. bb runs host-side; sandboxes bind-mount a home directory, so bb
env dirs (`~/.bb/personal-workspaces/env_<id>`) exist host-side only. Every
container shell then dies on start (`cd: No such file or directory`,
exit 126), and non-bash tools fail the same way.

## Install (inside the container, once)

```bash
git clone --depth 1 https://github.com/WARParrot/bb-docker-reroute.git /tmp/bdr
bash /tmp/bdr/bin/bb-docker-route install
exec bash -l   # or open a new shell
bb-docker-route doctor
```

After that: every new shell auto-provisions missing env dirs, a self-healing
`cd` creates-and-enters missing env dirs (bash and children), and a wiped
install restores itself on the next shell start (local checkout → git).

## Host side (once, covers non-bash tools)

The tool-shells and non-bash processes never read `~/.bashrc`. On the host:

```bash
nohup bash /path/to/repo/components/host/env-watcher.sh \
  >/var/log/bdr-watcher.log 2>&1 &
```

It mirrors any `~/.bb/personal-workspaces/env_*` into every sandbox home
(guarded: writes only under sandbox homes). With the watcher running, even
non-bash tools find their env dir before first use — no container install
strictly required.

## Commands

```bash
bb-docker-route provision [env-id]   # create missing env dir now
bb-docker-route status               # JSON probe
bb-docker-route doctor               # full component check
bb-docker-route remove               # full revert (bashrc blocks, symlink, state)
```

## Notes

- Repo: https://github.com/WARParrot/bb-docker-reroute (public, CI-tested).
- Removal is clean and additive-install only: no bb defaults are touched.
- Host-side permanent alternative: `mkdir -p <sandbox-home>/.bb/personal-workspaces/env_<id>`
  on the host per environment (the watcher automates exactly this).
