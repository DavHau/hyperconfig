# Run in the hermes venv as the agent's user before its gateway unit
# starts (./agents.nix, preStart), once per HERMES_HOME (the agent's and
# each named profile's): settle memory writes the background review
# staged for /memory approve before memory.background_consolidation was
# "auto" (patches/hermes-memory-background-consolidation.patch). Each one
# that still matches its pinned entries is applied after a snapshot in
# memories/.history/; one that no longer matches is copied whole to
# memories/.history/dropped/<id>.json, then dropped; both are logged
# there. Records over the removal cap, and ones whose store could not be
# read or written, stay pending for the next start. A no-op when the mode
# is "stage" or nothing is pending. Never fails the start: the unit runs
# it under `timeout 20s` and goes on after any error.
#
# Replaying, not discarding: the staged batches carry facts the review
# wanted to add alongside the consolidation (an all-or-nothing batch), so
# dropping them would lose those facts; the next review only re-proposes
# what is still in its recent conversation window.
import sys

from tools import write_approval as wa
from tools.memory_tool import background_consolidation_mode, replay_background_pending


def main() -> int:
    home = sys.argv[1] if len(sys.argv) > 1 else ""
    if not wa.pending_count(wa.MEMORY):
        return 0
    if background_consolidation_mode() != "auto":
        return 0
    counts = replay_background_pending()
    print(f"hermes: staged memory writes in {home}: {counts['applied']} applied, "
          f"{counts['dropped']} no longer matched (dropped, kept in memories/.history/dropped/), "
          f"{counts['kept']} left pending",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
