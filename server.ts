import type { BbPluginApi } from "@get-bb/plugin-sdk";
import { copyFileSync, existsSync, mkdirSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, relative } from "node:path";

/**
 * bb-docker-route server entry.
 *
 * Shell-side (bin/bb-docker-route install) wires the self-healing bootstrap
 * into the sandbox shell. Server-side (this file, v2.3.2): the attachment
 * mirror is a long-lived background service inside the bb server on the HOST,
 * with the algorithm embedded (pure node:fs) — no external script lookup,
 * so the service cannot fail to start because of install-layout differences.
 * (components/host/attachment-watcher.sh remains for manual/CLI use and
 * mirrors the same algorithm; the hermetic battery exercises both.)
 *
 * User story: "As a developer attaching a file to a bb thread, I want the
 * file to appear inside my agent's sandbox automatically — while bb runs,
 * without running anything myself."
 *
 * Acceptance:
 *   1. bb server start / `bb plugin reload bb-docker-route` (no bb restart)
 *      → service Running, thread-storage mirrored within seconds.
 *   2. New attachments appear within ~5s (poll cadence).
 *   3. No thread-storage / no sandbox homes yet → silent wait, never an error.
 *   4. Writes only under ~/.hermes/sandboxes/**\/home/.bb/thread-storage;
 *      never deletes sandbox files.
 *   5. Sandbox layouts: sandboxes/<name>/home and sandboxes/<backend>/<name>/home
 *      (e.g. docker/default) — both matched.
 */

const POLL_MS = 5_000;

const isDir = (p: string): boolean => {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
};

/** Depth-first list of files under dir (missing dir -> empty). */
function walkFiles(dir: string, out: string[] = []): string[] {
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    return out;
  }
  for (const name of names) {
    const p = join(dir, name);
    if (isDir(p)) walkFiles(p, out);
    else out.push(p);
  }
  return out;
}

/**
 * Sandbox homes at both known nesting depths:
 *   ~/.hermes/sandboxes/<name>/home
 *   ~/.hermes/sandboxes/<backend>/<name>/home   (e.g. docker/default)
 */
function sandboxHomes(home: string): string[] {
  const root = join(home, ".hermes", "sandboxes");
  let level1: string[];
  try {
    level1 = readdirSync(root);
  } catch {
    return [];
  }
  const homes: string[] = [];
  for (const a of level1) {
    const pa = join(root, a);
    const direct = join(pa, "home");
    if (isDir(direct)) homes.push(direct);
    let level2: string[];
    try {
      level2 = readdirSync(pa);
    } catch {
      continue;
    }
    for (const b of level2) {
      const nested = join(pa, b, "home");
      if (isDir(nested)) homes.push(nested);
    }
  }
  return homes;
}

/**
 * One bidirectional env-dir sync pass between the HOST env dirs
 * (~/.bb/personal-workspaces/env_<id>) and every sandbox home's shadow copy
 * (.bb/personal-workspaces/env_<id>). Files missing or older on the target
 * side are copied over; shadow-only env dirs (agent cd-shim births) are
 * backfilled to the host so bb reads agent-written files. Additive by
 * design: never deletes.
 */
function envSyncPass(home: string): { files: number; homes: number } {
  const src = join(home, ".bb", "personal-workspaces");
  const homes = sandboxHomes(home);
  if (!isDir(src) || homes.length === 0) return { files: 0, homes: 0 };

  let copied = 0;
  const syncPair = (a: string, b: string) => {
    for (const [from, to] of [
      [a, b],
      [b, a],
    ] as const) {
      if (!isDir(from)) continue;
      for (const file of walkFiles(from)) {
        const rel = relative(from, file);
        const dst = join(to, rel);
        if (existsSync(dst) && statSync(dst).mtimeMs >= statSync(file).mtimeMs) continue;
        mkdirSync(dirname(dst), { recursive: true });
        copyFileSync(file, dst);
        copied++;
      }
    }
  };
  for (const homeDir of homes) {
    const pw = join(homeDir, ".bb", "personal-workspaces");
    for (const env of readdirSync(src)) {
      const hostEnv = join(src, env);
      if (!isDir(hostEnv) || !env.startsWith("env_")) continue;
      syncPair(hostEnv, join(pw, env));
    }
    for (const env of (() => {
      try {
        return readdirSync(pw).filter((e: string) => e.startsWith("env_") && isDir(join(pw, e)));
      } catch {
        return [] as string[];
      }
    })()) {
      if (!isDir(join(src, env))) {
        mkdirSync(join(src, env), { recursive: true });
        syncPair(join(src, env), join(pw, env));
        copied++;
      }
    }
  }
  return { files: copied, homes: homes.length };
}

/**
 * One agent->host sync pass: for every sandbox home, copy files under any
 * …/Attachments/ subtree (and ONLY under Attachments — thread metadata stays
 * host-authoritative) into ~/.bb/thread-storage when missing or newer there.
 * This is how files an agent creates inside its sandbox become downloadable
 * bb attachments. Additive: never deletes.
 */
function agentAttachmentsPass(home: string): { files: number; homes: number } {
  const hostStorage = join(home, ".bb", "thread-storage");
  const homes = sandboxHomes(home);
  if (homes.length === 0) return { files: 0, homes: 0 };

  let copied = 0;
  for (const homeDir of homes) {
    const sandboxStorage = join(homeDir, ".bb", "thread-storage");
    let threads: string[];
    try {
      threads = readdirSync(sandboxStorage);
    } catch {
      continue;
    }
    for (const thread of threads) {
      const sandboxThread = join(sandboxStorage, thread);
      if (!isDir(sandboxThread)) continue;
      for (const entry of readdirSync(sandboxThread)) {
        const attachmentsDir = join(sandboxThread, entry);
        if (entry !== "Attachments" || !isDir(attachmentsDir)) continue;
        const hostThread = join(hostStorage, thread);
        if (!isDir(hostThread)) continue;   // only threads that exist host-side
        for (const file of walkFiles(attachmentsDir)) {
          const rel = relative(attachmentsDir, file);
          const dst = join(hostThread, "Attachments", rel);
          if (existsSync(dst) && statSync(dst).mtimeMs >= statSync(file).mtimeMs) continue;
          mkdirSync(dirname(dst), { recursive: true });
          copyFileSync(file, dst);
          copied++;
        }
      }
    }
  }
  return { files: copied, homes: homes.length };
}

/**
 * One mirror pass: copy files from ~/.bb/thread-storage into every sandbox
 * home's .bb/thread-storage when missing or older than the source.
 * Additive by design: never deletes, never overwrites newer target files.
 */
function mirrorPass(home: string): { files: number; homes: number } {
  const src = join(home, ".bb", "thread-storage");
  const homes = sandboxHomes(home);
  if (!isDir(src) || homes.length === 0) return { files: 0, homes: 0 };

  let copied = 0;
  for (const file of walkFiles(src)) {
    const rel = relative(src, file);
    const st = statSync(file);
    for (const homeDir of homes) {
      const dst = join(homeDir, ".bb", "thread-storage", rel);
      if (existsSync(dst) && statSync(dst).mtimeMs >= st.mtimeMs) continue;
      mkdirSync(dirname(dst), { recursive: true });
      copyFileSync(file, dst);
      copied++;
    }
  }
  return { files: copied, homes: homes.length };
}

export default function plugin(bb: BbPluginApi) {
  bb.log.info("bb-docker-route registered: container-first session routing");

  bb.background.service("env-sync", {
    start(signal) {
      bb.log.info(`env sync service started (poll ${POLL_MS / 1000}s, embedded)`);
      const run = () => {
        try {
          const { files, homes } = envSyncPass(homedir());
          if (files > 0) bb.log.info(`env sync: ${files} file(s) <-> ${homes} sandbox home(s)`);
        } catch (err) {
          bb.log.warn(`env sync pass failed: ${err instanceof Error ? err.message : String(err)}`);
        }
      };
      run();
      const timer = setInterval(run, POLL_MS);
      return new Promise<void>((resolve) => {
        signal.addEventListener(
          "abort",
          () => {
            clearInterval(timer);
            bb.log.info("env sync service stopped");
            resolve();
          },
          { once: true },
        );
      });
    },
  });

  bb.background.service("agent-attachments-sync", {
    start(signal) {
      bb.log.info(`agent attachments sync started (poll ${POLL_MS / 1000}s)`);
      const run = () => {
        try {
          const { files, homes } = agentAttachmentsPass(homedir());
          if (files > 0) bb.log.info(`agent attachments: ${files} file(s) -> bb thread storage`);
        } catch (err) {
          bb.log.warn(`agent attachments pass failed: ${err instanceof Error ? err.message : String(err)}`);
        }
      };
      run();
      const timer = setInterval(run, POLL_MS);
      return new Promise<void>((resolve) => {
        signal.addEventListener(
          "abort",
          () => {
            clearInterval(timer);
            bb.log.info("agent attachments sync stopped");
            resolve();
          },
          { once: true },
        );
      });
    },
  });

  bb.background.service("attachment-mirror", {
    start(signal) {
      bb.log.info(`attachment mirror service started (poll ${POLL_MS / 1000}s, embedded)`);
      const run = () => {
        try {
          const { files, homes } = mirrorPass(homedir());
          if (files > 0) bb.log.info(`attachment mirror: ${files} file(s) -> ${homes} sandbox home(s)`);
        } catch (err) {
          bb.log.warn(`attachment mirror pass failed: ${err instanceof Error ? err.message : String(err)}`);
        }
      };
      run();
      const timer = setInterval(run, POLL_MS);
      return new Promise<void>((resolve) => {
        signal.addEventListener(
          "abort",
          () => {
            clearInterval(timer);
            bb.log.info("attachment mirror service stopped");
            resolve();
          },
          { once: true },
        );
      });
    },
  });
}
