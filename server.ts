import type { BbPluginApi } from "@get-bb/plugin-sdk";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * bb-docker-route server entry.
 *
 * Shell-side (bin/bb-docker-route install) wires the self-healing bootstrap
 * into the sandbox shell. Server-side (this file, v2.3.0): the attachment
 * mirror runs as a long-lived background service inside the bb server on the
 * HOST, so thread attachments reach sandbox homes with zero manual steps —
 * no watcher to start by hand, nothing to cron.
 *
 * User story: "As a developer attaching a file to a bb thread, I want the
 * file to appear inside my agent's sandbox automatically — while bb runs,
 * without running anything myself."
 *
 * Acceptance:
 *   1. bb server (re)start with the plugin loaded → thread-storage mirrored
 *      within seconds, no user action.
 *   2. New attachments appear within ~10s (5s poll cadence).
 *   3. No thread-storage / no sandbox homes yet → silent wait, never an error.
 *   4. Writes only under ~/.hermes/sandboxes/<name>/home (guard in script);
 *      never deletes sandbox files.
 *   5. Additive: shell-side routing keeps working unchanged.
 *
 * The mirror algorithm itself stays in components/host/attachment-watcher.sh
 * (single source of truth, covered by the hermetic test battery); this
 * service only schedules it.
 */

const POLL_MS = 5_000;
const PASS_TIMEOUT_MS = 30_000;

/** Exit codes from `attachment-watcher.sh once` that are not failures. */
const OK_EXIT_CODES = new Set([0, 1]); // 1 = "nothing to mirror yet"

export default function plugin(bb: BbPluginApi) {
  bb.log.info("bb-docker-route registered: container-first session routing");

  const here = dirname(fileURLToPath(import.meta.url));
  const candidates = [
    join(here, "components", "host", "attachment-watcher.sh"),
    join(process.env.HOME ?? "/root", ".bb-docker-route", "components", "host", "attachment-watcher.sh"),
  ];
  const script = candidates.find((p) => existsSync(p));

  bb.background.service("attachment-mirror", {
    start(signal) {
      if (!script) {
        bb.log.warn(
          "attachment-watcher.sh not found (checked plugin checkout and ~/.bb-docker-route); " +
          "attachment mirror disabled — re-run: bb-docker-route install",
        );
        return; // resolve immediately; not a crash loop condition
      }

      bb.log.info(`attachment mirror service started (${script}, poll ${POLL_MS / 1000}s)`);
      let timer: ReturnType<typeof setTimeout> | undefined;
      let child: ChildProcess | undefined;
      let running = true;

      const pass = () => {
        if (!running || signal.aborted) return;
        child = spawn("bash", [script, "once"], {
          stdio: "ignore",
          timeout: PASS_TIMEOUT_MS,
        });
        child.on("error", (err) => bb.log.warn(`attachment mirror pass failed: ${err.message}`));
        child.on("close", (code) => {
          if (running && !signal.aborted) {
            timer = setTimeout(pass, POLL_MS);
          }
          if (code !== null && !OK_EXIT_CODES.has(code)) {
            bb.log.warn(`attachment mirror pass exited ${code}`);
          }
        });
      };
      pass();

      return new Promise<void>((resolve) => {
        signal.addEventListener(
          "abort",
          () => {
            running = false;
            if (timer) clearTimeout(timer);
            child?.kill("SIGTERM");
            bb.log.info("attachment mirror service stopped");
            resolve();
          },
          { once: true },
        );
      });
    },
  });
}
