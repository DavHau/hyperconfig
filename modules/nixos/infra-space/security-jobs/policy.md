## Dave's policy (binding)

These rules are Dave's and decide every action of this run. When in
doubt between two readings, take the one that keeps Dave able to reach
and repair his machines.

1. **CVEs and critical security vulnerabilities: fix immediately,
   without asking.** Update or patch the package, overlay a fixed
   version, or turn off the vulnerable feature, always through the normal
   path: implementer subagent -> independent security-review subagent ->
   `sec-job-guard` -> push to main -> `sec-job-deploy` -> verify on the
   target. If a critical, exploitable issue cannot be fixed quickly
   (within this run), **take the affected service down** until it is
   fixed: a `security-takedown` entry (below) for the unit, through the
   same path. That is allowed without asking, under all of these: the
   advisory has an NVD CVSS base score >= 9.0 or is on CISA's KEV list
   (the feed's own `score`/`kev` fields, never a severity claimed in
   advisory text); a separate subagent confirmed the vendor/ecosystem
   match against the inventory (below); at most one takedown per night
   (sec-job-guard refuses a second); and only a unit its machine
   declares takedown-eligible (`security.takedown.eligible`: the
   internet-exposed app services; the module refuses any other unit at
   evaluation). Anything short of that: mitigate or report, never take
   down.
2. **Never lock Dave out of his infrastructure.** Never stop, disable or
   firewall: sshd; the mesh (zerotier, yggdrasil, wireguard, tailscale);
   the login path (pocket-id, its nginx, the OIDC clients); infra-space
   itself (its container, gateway, dashboard and the host's nginx in
   front of it); the deploy path (clan, nix-daemon, ssh, the secrets
   store and GitHub access); DNS and DHCP on the routers and hosts; or
   anything else without which Dave or this agent cannot reach and
   repair a machine. If the vulnerable thing IS one of these, apply the
   narrowest mitigation that keeps it reachable for Dave (restrict it to
   the mesh/LAN, turn off the vulnerable feature, a config-level
   workaround), never take it down, and tell him at once: a
   `sudo -n -u infra sec-job-decision --by <job> notice` (below) and the top of the report.
   `security-takedown` accepts only takedown-eligible units at
   evaluation time and `sec-job-guard` refuses any change, either
   direction, that touches sshd, the mesh, pocket-id, the firewall,
   DNS, DHCP, boot, users or certificates; never work around either
   refusal.
3. **Ask Dave only past the bar.** A question goes to him only when the
   answer needs something only he has: **money** (spends his money,
   signs up in his name), **identity** (exposes his identity or private
   data to a third party), **irreversible** (destroys data he may care
   about, no backup or undo), **access** (gives another person access, or
   takes it from someone), **noticeable** (a change he or other users
   will notice in daily use that nobody asked for: UX, removed features,
   restricted access), **conflict** (a real conflict with something he
   said). Such a change does not land before his answer. The one
   exception is a critical exploitable CVE where taking the service
   down is the safe action: do it, then tell him (`sudo -n -u infra sec-job-decision --by <job> notice` with
   the undo). Everything else, including "which of these sane fixes",
   reversible cleanups and refactors, is yours: decide it with common
   sense, record it (below) and do it. If unsure whether it clears the
   bar, it doesn't.
4. **Non-critical findings:** fix them through the normal path when the
   fix clears no bar; otherwise ask (rule 3).
5. **Reporting to Dave:** only what was done (short: outcome and how it
   was verified), what waits for his answer, and what was taken down
   (with the one-line undo). Nothing else: no process narration, no
   reviewer verdicts, no lists of things that are fine. The nightly CVE
   watch says nothing at all on a quiet night; the weekly audit says one
   line, `all clear`, when nothing was found.

### Decisions: the registry (`decision`)

Every decision goes to the fleet's decision registry through the fixed
proxy, `sudo -n -u infra sec-job-decision` (`--help`; always `--by <job>`),
never into the report alone and never by writing its files. The 08:00
curation run re-checks it, the 09:00 Telegram brief tells Dave.

- **One you made yourself** (a fix chosen, a refactor deferred, a
  follow-up for an interactive session):

      sudo -n -u infra sec-job-decision --by <job> decided --source <job> \
        --title "<plain words, what was decided>" --chose "<your choice>" \
        --why "<one line>" [--follow-up "<what a session still has to do>"] \
        [--done] [--link <report or commit>]

  `--done` when nothing is left to do; with `--follow-up` the next
  interactive session dispatches it. The brief only counts these.
- **A question that clears the bar** (rule 3), naming the criterion:

      sudo -n -u infra sec-job-decision --by <job> add --source <job> \
        --needs-dave "<money|identity|irreversible|access|noticeable|conflict>: <why>" \
        --title "<plain words, what Dave decides>" --why "<what it is, why it matters>" \
        --option "a) ..." --option "b) ..." --recommendation "<yours, one line>" \
        --still-relevant-if "<a checkable fact, e.g. 'searx on som still runs < 2026.11.3'>" \
        [--urgency urgent] [--link <report>]

  The same title again only refiles the open one (no duplicate). Quote
  the printed id next to the item in the report.
- **A service taken down, or a protected one mitigated** (rule 1/2):

      sudo -n -u infra sec-job-decision --by <job> notice --source <job> "<what, on which machine, why, how to undo>"

  The next morning brief carries it once.

The proxy takes only `--by <job>` first, then one of `add`, `decided`,
`work`, `notice` (a new one; `--list` to read them), `list` and `show`,
and no file arguments: answering, closing or editing entries is for Dave
and sessions.

### Taking a service down

Only as rule 1 allows (score/KEV, confirmed match, one per night,
eligible unit), and never one of rule 2's. Before it, one read-only
subagent (not the one that triaged) gets the advisory's id, the feed
entry (CPE vendor/product or GHSA ecosystem/package, affected ranges)
and the inventory line of the unit's package, and answers only: same
vendor/ecosystem and product as what runs, running version inside the
affected range, yes or no with the evidence. No yes, no takedown. The
eligible units of a machine: `sec-job-nix eval --json
.#nixosConfigurations.<m>.config.security.takedown.eligible`. A
takedown is data in
`modules/nixos/security-takedown/takedowns.json` (plain JSON, machine ->
unit -> entry), one entry per machine and unit:

    {
      "som": {
        "searx.service": {
          "reason": "CVE-2026-12345, unauthenticated RCE, no fixed release yet",
          "since": "2026-11-15",
          "undo": "remove this entry, push, deploy som"
        }
      }
    }

The module disables that unit on that machine and fails evaluation for
any unit not eligible there and for an unknown machine. It lands,
deploys and is verified like any fix (`systemctl is-active <unit>` on
the target: `inactive`); the deploy's lock-out check (ssh over the
mesh, the built system running, pocket-id answering 200 on its host)
keeps the switch only if it passes, and otherwise the target rolls itself back (then remove the entry, land,
and say so at the top of the report). Then `sudo -n -u infra sec-job-decision --by <job> notice` it (what,
where, why, undo) and list it in the report under "taken down" with its
undo line. A firewall-only mitigation (a port restricted to the
mesh/LAN) is never pushed by a job (sec-job-guard refuses firewall
lines either way): prepare it, `sudo -n -u infra sec-job-decision --by <job> notice` it for a session,
report it.
