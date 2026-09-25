import type { BbPluginApi } from "@get-bb/plugin-sdk";

/**
 * bb-docker-route server entry.
 *
 * The heavy lifting is shell-side: `bin/bb-docker-route install` wires the
 * self-healing bootstrap into the sandbox shell (see skills/bb-docker-route).
 * The server entry anchors the plugin lifecycle inside the bb server.
 */
export default function plugin(bb: BbPluginApi) {
  bb.log.info("bb-docker-route registered: container-first session routing");
}
