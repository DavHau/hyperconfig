---
name: nixpkgs-bump
description: Run, watch and fix som's nixpkgs bump of the hyperconfig fleet flake. Use it when asked to bump hyperconfig or nixpkgs, to report on a bump, or when a bump run hands you a failing evaluation or build.
---

# The nixpkgs bump of hyperconfig

som updates hyperconfig's nixpkgs input on its own, nightly, and whenever you
ask for it. A run: fetch upstream `master`, `nix flake update nixpkgs`, commit
`flake.lock: update nixpkgs`, then evaluate every machine and build those for
x86_64-linux (the others only evaluate), one after the other. If anything
fails, the run hands the failure to you (a separate session, started by the
run), takes your commits back, checks them and verifies again, up to
@ROUNDS@ times. Green ends on branch `@DELIVER@` (plus a tag
`@DELIVER@-<date>`), red on `@FAILED@`, in som's local repo; the user pulls
with

    git fetch root@som:/var/lib/nixpkgs-bump/hyperconfig.git @DELIVER@

Nothing is pushed anywhere and nothing is deployed.

Your terminal and file tools run in your slot, not on som. You cannot reach
som from there; the run talks to you through two directories:

- `@PUBLIC@` (read-only): `status.json`, `runs/<run>/` (`pipeline.log`, and
  per round `round-<n>/<machine>.log`, `failed`, `machines`), `handoff/`.
- `@AGENT@` (yours): `hyperconfig/`, the clone a hand-off gives you, and
  `requests/`.

Your slot is up from boot and managed for you: the `slot` command of the
container-slot skill runs on som, which your tools do not reach; ignore it.

If `git` or `nix` is missing in a shell: `export PATH=@TOOLS@/bin:$PATH`.

## When the user asks for a bump

1. Read `@PUBLIC@/status.json`. If `state` is `running` or `agent-fixing`, a
   run is already going: watch that one instead of starting another.
2. Start one: `touch @AGENT@/requests/bump`. Within seconds `status.json`
   shows a new `run` with `"trigger": "request"` and `"state": "running"`.
   The file's content does not matter and the request is consumed by the
   run.
3. Watch: `status.json` (`state`, `round`, `failed`) and
   `tail -n 30 @PUBLIC@/runs/<run>/pipeline.log`. A run takes from minutes
   (nothing to rebuild) to hours (a mass rebuild); check every few minutes,
   do not spin.
4. Report when `state` is final:
   - `unchanged`: upstream already has the newest nixpkgs; nothing to do.
   - `green`: nixpkgs `nixpkgs_old` -> `nixpkgs_new`, the fixes in `fixes`
     (empty: the bump alone was green), delivered as `delivered` at `commit`,
     and the fetch command above.
   - `red`: what still fails (`failed`, with the reason from its log), the
     fixes that were taken, branch `@FAILED@` at `commit`, logs under `logs`.
   - `error`: the run itself broke; quote the end of its `pipeline.log`.

## When a run hands you a failure

The prompt names the run, the round, your clone and the failing machines'
logs (copies under `@PUBLIC@/handoff/logs/`). Do not request a bump then: you
are inside that run, and it re-verifies on its own after you finish.

1. Work in `@AGENT@/hyperconfig`, branch `nixpkgs-bump`, already at the
   run's commit. Read each log from its first real error, not its last line.
2. Reproduce only what failed, one machine at a time:
   - evaluation: `nix eval .#nixosConfigurations.<m>.config.system.build.toplevel.drvPath`
   - build: `nix build --no-link .#nixosConfigurations.<m>.config.system.build.toplevel`
   (the run's own attribute is in its log header; `installer` uses its image).
   The slot's profile sets `max-jobs = @MAXJOBS@` and `cores = @CORES@`: som
   runs other work, so do not raise them and do not start several builds at
   once. Never use `--impure`.
3. Fix the cause, one commit per fix, with a message that says what nixpkgs
   changed and what you adapted (e.g. `vit: services.foo.bar was renamed to
   services.foo.baz`).
4. Re-run the failing evaluation or build to confirm, then go on to the next
   failure. Finish with a short summary of every fix and anything left.

Allowed:
- adapting to renamed or removed options, packages and functions,
- small overlays or patches for a package that broke,
- pinning ONE package to an older nixpkgs, with a comment that names the
  upstream issue or PR.

Forbidden (the run refuses commits that do any of these, or the user will):
- `allowBroken`, `allowInsecure`, `permittedInsecurePackages`,
  `allowUnsupportedSystem`, `--impure`,
- disabling services, modules or machines to make an evaluation pass,
- touching `vars/`, `sops/` or anything secret,
- changing flake inputs other than adding the one old-nixpkgs pin above;
  never move `nixpkgs` itself,
- rewriting or dropping the run's commits (amend, rebase, reset, force):
  your commits must sit on top of it.
