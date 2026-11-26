---
name: nmm-tools
description: "Use for every command in the asof-agents or asof slot (agent or root): remote CLI, owner cards, swarm steering."
---

# Tools for nmm (asof-agents)

Managed by hyperconfig and rewritten on every deploy: don't edit it; your
own lessons go into the `nmm` skill or its references/.

## `remote asof-agents`: never raw ssh

Every remote command goes through `remote` (`remote --help`, `remote
asof-agents help`). It sends commands without nested quoting, caps output
(head + tail) and keeps the whole output in a local file whose path it
prints: read or `search_files` that file instead of re-running with
`| head`. The exit code is the remote command's (124 = timed out).

    remote asof-agents run -- swarm queue                  # cwd ~/nmm
    remote asof-agents run --cwd hermes-workspaces/x -- jj st
    remote asof-agents run --timeout 600 --max-lines 40 -- cargo test -p foo
    remote asof-agents run --script $TMPDIR/inv.sh arg1     # local script, runs there
    remote asof-agents put $TMPDIR/body.md                  # -> /scratch/hermes/body.md
    remote asof-agents get /home/agent/x.json               # -> $TMPDIR/remote/get/x.json

- `run -- CMD ARGS` passes the words exactly: no shell there. Anything
  with pipes, loops, `&&`, heredocs, python or sqlite goes into a local
  script (`write_file`), then `run --script`. Inside the script quote
  normally: it is one level, sqlite string literals in single quotes.
- Files for the slot go through `put` into `/scratch/hermes`
  (unsnapshotted, never backed up, yours to clean), never `/tmp` (shared
  with the swarm, cleaned daily); then pass the path, e.g.
  `run -- swarm task new ... --body-file /scratch/hermes/body.md`.

## Root in the swarm's slots: `remote asof-agents-root`, `remote asof-root`

Full root shells (own key, only from som), for what `agent` can't do:
owner cards, placing keys into asof, anything that needs root. Same
`run`/`put`/`get` as above; cwd is /root, put/get scratch
`/root/.cache/hermes-remote` (root-only; `put` writes 0600). Raw `ssh asof-agents-root` / `ssh asof-root` work
too (pty allowed), but prefer `remote`.

    remote asof-agents-root run -- swarm owner list
    remote asof-agents-root run -- swarm owner show c-some-card
    remote asof-agents-root run -- swarm owner approve c-some-card --text "..."
    remote asof-agents-root run -- swarm owner answer|done|dismiss|reject c-some-card --text "..."

- Owner cards: approve, answer, reject, done or dismiss only a card that
  comes from Dave's own chat request (he asked for exactly that work, or
  names the card); anything else: show it to Dave and ask. `swarm owner
  list|show` is always fine.
- Placing a key into asof: only a key Dave asks you to place (the
  project's own secret flow comes first), its value from his vault or a
  file he points to, never through the chat. `put` it (lands 0600 in the
  root-only scratch), then `run -- install -m 0600 -o root -g root
  /root/.cache/hermes-remote/F /final/path` and `run -- rm
  /root/.cache/hermes-remote/F`; confirm only by name, size or hash.
- Root in asof also reaches that slot's own account secrets (env files,
  keys under /var/lib/...): never print, cat, grep, copy, move or send
  them into the chat, logs or another slot; list key NAMES only (`sed -E
  's/=.*/=<set>/'`). Don't change files you don't own a task for, and
  never restart asof's services or the slot unless Dave asks.
- Root commands don't go through the swarm's review: say what you ran.

## The project's read-only account: `remote asof-agents ro`

    remote asof-agents ro asof status
    remote asof-agents ro journalctl -u asofd -n 50 -o cat
    remote asof-agents ro df -h -T /
    remote asof-agents ro timeout 280 asof query --root /vault/parquet --dataset D --as-of T --from A --to B --columns c1,c2 --format jsonl

One command per call, no shell (no pipes, `;`, globs); filter with a
`run --script` that calls `ssh asof ...` and post-processes there. Its
grammar (`remote asof-agents help` has the full list): systemctl
status/show/list-units/list-timers/is-active/is-failed; journalctl with
-u/-t/-g/-n/-p/-o/-S/-U, no positionals; df with separate flags (`-h -T`,
never `-hT`); `asof status`; `asof query` with --dataset --as-of --from --to
--columns --visibility --limit --format and optionally `--root
/vault/parquet` (never --url/--token, no positionals); cat/head/tail/ls of
absolute paths under its read prefixes (/var/lib/asof* and the one its
refusal names; no secrets) (`head -n 20`,
never `-20`); each optionally after `timeout N` (N <= 300). A refusal
prints the allowlist: read it before retrying.

## The swarm: status, steering, editing

    remote asof-agents task-status t-abc-1 t-def-2   # one line each
    remote asof-agents pane t-abc-1 80               # its herdr pane + last 80 lines
    remote asof-agents steer t-abc-1 "New fact: ..." # message into the running agent

- herdr's session is `swarm` (`herdr --session swarm ...`); `herdr-swarm`
  is only the systemd service name. A task's pane is the one whose cwd is
  `~/workspaces/<task-id>`.
- A task that is still `ready`/`blocked`: change it with `swarm task edit
  ID --body-file F --reason R`. Once it runs, edit is refused: steer its
  agent instead. A blocked agent refuses prompts.
- `swarm task new --summary` takes at most 25 words; there is no hold
  command.

## Waiting

Never sleep in the foreground (no `sleep 60`, no sleep loops). Long probes
and polls run with `terminal(background=true, notify_on_complete=true)` or
as an asof job; a foreground call is capped at 600 s. To wait for a
condition, background one `timeout N bash -c 'until CHECK; do sleep 1;
done'` with notify, and take Dave's next message meanwhile. Never `nohup`
or `&` inside a foreground command.

## Browser and payment forms

Never `browser_vision` (screenshots) while a page holds vault-filled card
fields: the screenshot shows them in clear text. No screenshots of that
page until the form is submitted or closed.
