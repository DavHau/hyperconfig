"""Swarm task helpers for `remote asof-agents pane|steer|task-status` (../dave-hermes-nmm.nix).

Runs in the slot as python3 -c, the subcommand first. The swarm's agents run in herdr's session
`swarm` (its services are named herdr-swarm; the session is not), one pane per task whose cwd is
~/workspaces/<task-id>.

  pane TASK [LINES]      the task's panes (id, status, cwd, title); with LINES the live pane's tail
  steer TASK TEXT...     prompt the task's live agent with TEXT (one message)
  status TASK...         one line per task: id, status, wait_for, updated, live pane, title
"""

import json
import os
import subprocess
import sys


def run(argv):
    p = subprocess.run(argv, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def agents():
    rc, out, err = run(["herdr", "--session", "swarm", "agent", "list"])
    if rc:
        sys.exit("herdr agent list (session swarm) failed: " + (err or out).strip())
    return json.loads(out)["result"]["agents"]


def panes(task, every):
    found = [a for a in every if os.path.basename((a.get("cwd") or "").rstrip("/")) == task]
    return sorted(found, key=lambda a: a.get("agent_status") == "done")


def line(a):
    return "\t".join(str(a.get(k, "")) for k in ("pane_id", "agent_status", "cwd", "terminal_title_stripped"))


def main(cmd, args):
    if cmd == "pane":
        if not args:
            sys.exit("usage: pane TASK [LINES]")
        ps = panes(args[0], agents())
        if not ps:
            sys.exit(f"no herdr pane with cwd ~/workspaces/{args[0]} (session swarm)")
        print("\n".join(map(line, ps)))
        if len(args) > 1:
            rc, out, err = run(["herdr", "--session", "swarm", "agent", "read", ps[0]["pane_id"], "--lines", args[1]])
            print(out + err, end="")
        return 0
    if cmd == "steer":
        if len(args) < 2:
            sys.exit("usage: steer TASK TEXT...")
        live = [a for a in panes(args[0], agents()) if a.get("agent_status") != "done"]
        if len(live) != 1:
            sys.exit(f"{len(live)} live panes for {args[0]}; steer needs exactly one (is the task running?)\n"
                     + "\n".join(map(line, live)))
        rc, out, err = run(["herdr", "--session", "swarm", "agent", "prompt", live[0]["pane_id"], " ".join(args[1:])])
        print(f"{live[0]['pane_id']} ({live[0].get('agent_status')}): {'prompted' if rc == 0 else 'FAILED'}")
        print((out + err).strip()[:2000])
        return rc
    if cmd == "status":
        if not args:
            sys.exit("usage: status TASK...")
        try:
            every = agents()
        except SystemExit:
            every = []
        worst = 0
        for task in args:
            rc, out, err = run(["swarm", "task", "show", task, "--json"])
            try:
                t = json.loads(out)
                t = t.get("task", t) if isinstance(t, dict) else None
            except ValueError:
                t = None
            if rc or not t or not t.get("status"):
                print(f"{task}\terror: {((err or out).strip().splitlines() or ['no output'])[0]}")
                worst = 1
                continue
            live = [a for a in panes(t.get("id", task), every) if a.get("agent_status") != "done"]
            pane = f"{live[0]['pane_id']}({live[0].get('agent_status')})" if live else "-"
            print("\t".join([t.get("id", task), str(t.get("status")), f"wait_for={t.get('wait_for') or '-'}",
                             f"updated={str(t.get('updated_at') or '-')[:16]}", f"pane={pane}",
                             (t.get("title") or "")[:70]]))
        return worst
    sys.exit(f"unknown subcommand {cmd}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2:]))
