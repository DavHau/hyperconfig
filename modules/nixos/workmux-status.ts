/**
 * Workmux status tracking extension for pi.
 *
 * Reports agent status to workmux for tmux window status display.
 * Vendored from https://github.com/raine/workmux (.pi/extensions/workmux-status.ts);
 * see https://workmux.raine.dev/guide/status-tracking
 *
 * When omp runs outside a workmux-managed tmux window, `workmux
 * set-window-status` simply fails and the error is swallowed, so this is a
 * no-op there.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  function setStatus(status: string) {
    pi.exec("workmux", ["set-window-status", status]).catch(() => {});
  }

  pi.on("agent_start", async () => {
    setStatus("working");
  });

  pi.on("agent_end", async () => {
    setStatus("done");
  });
}
