---
name: hygiene-report
description: The weekly hygiene run of hyperconfig - survey (unimported modules, dangling refs, naming off-scheme, duplicated mechanisms, oversized machine files), land the mechanical fixes through the normal path, propose the structural ones. Use it when hygiene-report.timer starts you (Saturday night), or when Dave asks for a hygiene pass.
---

# The weekly hygiene report

A timer on @MEMBER@ starts you every Saturday at 03:30 Asia/Bangkok
(after the 01:30 nixpkgs bump, whose lock it waits for). You survey hyperconfig's hygiene, fix what is mechanical
through the normal path, and write the structural rest into the report
as recorded decisions. The security audit runs the night after, on the
code you cleaned.

Time budget: about 4 hours. At most two subagents alive at once; one
build at a time.

@POLICY@

Hygiene changes are refactors: they must not change behaviour. The
check for that is the toplevel drvPath of every machine before and after
(som's always differs: its nginx references the repo source; explain any
other difference in one line, or drop the change).

@COMMON@

## 1. Workspace

    mkdir -p $TMPDIR/hygiene-report ~/hygiene-report/state
    ws=$(sec-hygiene-report-workspace create)

## 2. Survey

At `$ws`'s root:

    sec-job-nix run .#hygiene -- --report > $TMPDIR/hygiene-report/survey.txt
    sec-job-nix build .#checks.x86_64-linux.hygiene --no-link

The repo's own lint (`tools/hygiene/hygiene.py`, rules in
`CONVENTIONS.md`): `--report` lists every current violation by kind
(`unimported` modules, `dangling` paths, `generator` names off the
`<feature>-<what>` scheme or declared in a machine file, `sshkey`
literals outside the registries, `machine-loc` over budget);
`tools/hygiene/baseline.txt` is the known debt, `allowlist.txt` the
deliberate exceptions. The check fails on violations in neither (new
debt since it landed: fix those first) and on stale allowlist lines.
Confirm an `unimported` module by eval before deleting it (some are
reached by computed paths). Then by hand (grep, `skills/hyperconfig-map/references/map-*.md`),
**duplicated mechanisms**: the same thing implemented twice (disk unlock,
provider-key modules, textfile metrics exporters, per-owner loopback
`meta skuid` gates, oauth2-proxy setups, desktop-owner guesses). Compare
against the repo-cleanup proposal's known list when Dave's notes have one;
new copies since last week are the interesting part.

Trend: compare the counts with last week's
(`~/hygiene-report/state/last.json`; missing on the first run). Save this
week's counts there at the end.

## 3. Fix what is mechanical

Mechanical = no judgement about behaviour, drvPath identical on every
machine but som (reason-only):

- delete an unimported module, after `rg` and an eval check prove no
  machine reaches it (grep the generator names it declares in
  `vars/` too: a generator that exists in vars means it IS imported);
- fix a dangling reference in a comment (point it at the file that now
  holds the thing, or drop the reference);
- add a one-line header comment to a header-less module (what it is,
  from its code);
- delete commented-out code blocks in a module that is otherwise live
  (keep explanatory comments; never touch commented lines that document
  an option's alternative values);
- shrink `tools/hygiene/baseline.txt` for what the commit fixed
  (`python3 tools/hygiene/hygiene.py --update-baseline`; never to accept
  new debt);
- regenerate the repo map when modules moved or headers changed
  (`sec-job-nix run .#repo-map`), in the same commit.

One implementer subagent for the batch (normal path, rule 1 of the
common section), with the before/after drvPath comparison of every
machine in its report; then the security review (it also checks that
nothing deleted was live), guard, land. Deploy: hygiene changes are
behaviour-neutral, so deploy only if a machine's drvPath (besides som's
source reference) changed and the reviewer accepted the reason; usually
nothing to deploy. Cap: about 40 files per week, so the change stays
reviewable; the rest is next week's.

Not mechanical, never in this job's commit: renaming options or
generators (vars move with them), merging duplicated mechanisms,
splitting machine files, moving ssh keys into the registry (changes
who gets in if wrong). These are structural.

## 4. Structural findings: decide, record

A structural cleanup is a refactor: it is yours to decide (policy rule
3; no criterion of the bar applies to moving code without changing
behaviour). For each new or grown one, decide what should happen and
record it for an interactive session to dispatch:

    decision --by hygiene-report decided --source hygiene-report \
      --title "<plain words: merge X and Y into one module>" \
      --chose "<what, in one line>" --why "<one line>" \
      --follow-up "<the change a session should dispatch>" --link <report>

Only when it really clears the bar (it would change something Dave
notices daily, e.g. a desktop app or a login path, or it moves who gets
in, e.g. ssh keys into the registry) is it a question: `decision --by
hygiene-report add --needs-dave "<criterion>: <why>" ...` with options,
a recommendation and a `--still-relevant-if` a later run can check.
The same title again only refiles; look at `decision list --status all`
first and repeat one only when it got worse.

## 5. Report

Your last message is the report (~/hygiene-report/<UTC>.log and the
dashboard). Short:

- **Done:** what the commit cleaned (counts per category), commit id,
  "verified: drvPaths identical on <machines>, som reason-only".
- **Trend:** the counts that grew since last week, one line each.
- **Decided:** one line per new structural decision (title, id).
- **Waits for you:** title + criterion + decision id, new questions only.
- **Problems** (workspace left, a gate that failed).

Then `sec-hygiene-report-workspace remove $(basename $ws)`. The very
last line is exactly one of

    HYGIENE: clean
    HYGIENE: fixed
    HYGIENE: reported
    HYGIENE: failed

`clean` = nothing to fix and nothing new recorded (the report is one
line: "hygiene: nothing new"). `fixed` = a cleanup landed. `reported` =
only recorded decisions/questions/problems. Nothing after the line.
