---
name: security-audit
description: The weekly security audit of Dave's fleet (not CVEs) - exposure vs intent, auth on exposed services, secrets handling, container/agent isolation, sudo/polkit, ssh access, stale accounts, TLS, backups, monitoring gaps; diffed against last week; fix per Dave's policy. Use it when security-audit.timer starts you (Sunday night), or when Dave asks for a security audit.
---

# The weekly security audit

A timer on @MEMBER@ starts you every Sunday at 03:30 Asia/Bangkok
(after the 01:30 nixpkgs bump, whose lock it waits for), the day after
the hygiene run, on the cleaned-up code. Not
CVEs (that is the nightly cve-watch): configuration and exposure
mistakes. You compare what the machines actually do with what the repo
declares and intends, fix what can be fixed without changing behaviour,
decide the rest yourself (recorded), and ask Dave only what clears
the bar. When nothing was found, the report is one
line: `all clear`.

Time budget: about 5 hours. At most two subagents alive at once (a
read-only collector per area is fine, one after another); one build at
a time.

@POLICY@

@COMMON@

## 1. Workspace, tripwire, last week

    mkdir -p $TMPDIR/security-audit ~/security-audit/state
    ws=$(sec-security-audit-workspace create)
    cd "$ws" && sec-collect snapshot $TMPDIR/security-audit/before

Last week's findings: `~/security-audit/state/findings.json` (missing
on the first run). You write this week's there at the end (step 5).

## 2. Collect

    sec-collect exposure $TMPDIR/security-audit/exp

Then per machine, read-only over ssh (`ssh <m>.d bash -c "'...'"`;
offline machines: repo side only, marked so), into
`$TMPDIR/security-audit/<m>/`:

- **Exposure vs intent:** `<m>.ss` (live listeners) and `<m>.nft` against
  `<m>.declared.json` and the modules that open ports. For every
  listener not on loopback: which interface/address, which unit
  (`ss -p`), whether the firewall admits it from where (internet: sgp's
  public IPv4, edi, som's forwarded ports; LAN; mesh `ztXXXX`/`wg*`),
  and whether the repo intends that (the module's header says why it
  listens). A listener the firewall admits that no module intends, or a
  rule that admits more than the module says, is a finding. On som
  (multi-tenant) also loopback listeners without their own auth and
  without a `meta skuid` gate: every tenant reaches them.
- **Auth on every exposed service:** each exposed HTTP(S) service
  (nginx vhosts: `nix eval --json .#nixosConfigurations.<m>.config.services.nginx.virtualHosts --apply builtins.attrNames`)
  is behind pocket-id/oauth2-proxy/hermes OIDC or its own login. Probe
  unauthenticated from this container: `curl -sS -o /dev/null -w '%{http_code}'`
  on the vhost (no credentials; GET only; never submit forms).
  200 on something that should need a login is a finding.
- **Secrets:** clan vars generators with `deploy = true` whose secret
  is not needed on the machine (`clan.core.vars.generators.<g>.files.<f>.deploy`
  by eval); `secret = false` files that look secret (names like key,
  token, password, passphrase); world-readable files under `/run/secrets*`,
  `/var/lib/*/` secrets dirs, `/etc` (`find ... -perm -o+r -type f`
  names only, never contents); secrets in the store: search the
  evaluated `environment.etc` and units' `Environment=` for key-shaped
  strings with `grep -c`/`grep -l` only (never print a match), and
  report the file or option name, never the value.
- **Isolation:** containers and agent spaces (infra-space, spaces,
  slots, hermes agents): userns on or off, capabilities
  (`systemctl show -p CapabilityBoundingSet,AmbientCapabilities <unit>`),
  `PrivateUsers`, `NoNewPrivileges`, bind mounts of host sockets
  (nix-daemon, D-Bus, Wayland, docker) into guests, nix
  `trusted-users`/`allowed-users` per machine, who can reach som's
  nix-daemon (a trusted user is root on som).
- **sudo/polkit:** `security.sudo.extraRules`, `wheelNeedsPassword`,
  members of `wheel` per machine, polkit rules (`/etc/polkit-1/rules.d`),
  security wrappers (setuid) beyond nixpkgs' defaults.
- **ssh:** who can log in where: `AuthorizedKeysFile` contents' key
  fingerprints and comments per user per machine (`ssh-keygen -lf`),
  against `modules/admin-ssh-keys.nix` and the users modules; the CA and
  host certs; `PasswordAuthentication`, `PermitRootLogin`,
  `KbdInteractiveAuthentication`. A key on a machine that the repo does
  not declare (drift) is a finding.
- **Stale accounts:** normal users per machine (`getent passwd` uid >=
  1000) vs the repo; last logins (`lastlog`/`last -n 5` where present);
  pocket-id users and groups (from the repo's inventory, not the admin
  API) of people who no longer need access: a question for Dave
  (`--needs-dave "access: ..."`), never a removal.
- **TLS:** for each public vhost: certificate expiry (`openssl s_client`
  + `x509 -enddate`; < 14 days left is a finding), `ssl_protocols`.
  ACME units failed (`systemctl --failed`).
- **Backups and their restore path:** what is backed up (the repo's
  borg/restic/zfs send/syncoid units), last success per job
  (`systemctl show -p ActiveEnterTimestamp,Result` of the backup units,
  repository listing timestamps where readable without secrets), and
  whether a restore path is documented and was ever tested (docs/,
  module headers). A backup older than its interval x2, or data with
  none, is a finding.
- **Monitoring gaps:** machines and services without metrics/alerts
  (`modules/nixos/monitoring-*.nix`, the alert rules), e.g. the
  container units nobody sees (the known gap of these jobs), failed
  units that nothing alerts on.

## 3. Judge, diff, act

Every finding gets: machine(s), area, what is wrong (fact, with the
command output line that shows it, no secrets), severity, and whether it
is new, unchanged or fixed since last week (match by a stable key:
`<area>:<machine>:<subject>`).

Act by the policy:
- Exploitable now and critical (an unauthenticated admin interface on
  the internet, a world-readable private key): fix immediately through
  the normal path; if a fix would change behaviour, take the service
  down (`decision notice` with the undo; not protected services: those
  get the narrowest mitigation that keeps Dave able to get in, e.g.
  restrict to mesh/LAN, plus a notice). Rotate nothing yourself (it
  needs `clan vars generate`): `decision decided --chose "rotate <var>"
  --follow-up ...`, and the narrowest containment tonight.
- Fixable without a behaviour change (a missing `NoNewPrivileges` on a
  unit that does not need privileges, a file mode): the normal path. A
  stray firewall port or any other firewall, user, DNS or boot line is
  not pushed by a job, even as a narrowing (sec-job-guard refuses
  those lines both ways): `decision decided --follow-up` for a session. Batch them into
  one or two implementer passes.
- Clears the bar (closing a port someone uses, removing a user or a
  key, restricting someone's access, anything Dave would notice): a
  question (`decision --by security-audit add --needs-dave
  "<criterion>: <why>" ...`), never a change before his answer.
- Every other judgement call (which fix, defer to a session, accept a
  documented exception): decide it, `decision --by security-audit
  decided ...`.

Before acting on anything at all, re-check rule 2 of the policy: a
change that could cut ssh, the mesh, the login, infra-space, the deploy
path or DNS/DHCP is never yours.

## 4. Tripwire

    sec-collect snapshot $TMPDIR/security-audit/after
    diff $TMPDIR/security-audit/before/snapshot $TMPDIR/security-audit/after/snapshot

Differences are expected only where you deployed (`system`, maybe `nft`)
and on main (your landed commits). Anything else changed during the run
(keys, another machine's system): report it loudly under Problems.

## 5. Report

Write this week's findings (open ones, with key, severity, first seen)
to `~/security-audit/state/findings.json` (write_file, valid JSON).
Your last message is the report (~/security-audit/<UTC>.log and the
dashboard). Policy rule 5:

- **Done:** per fix: what, where, commit, verified how.
- **Taken down / mitigated:** service, machine, why, undo (each also a
  `decision notice`).
- **Waits for you:** title + criterion + decision id, new or changed
  questions only (an open one from last week: one line "still open:
  <ids>").
- **Since last week:** fixed (one line), new (counted).
- **Problems:** tripwire changes, offline machines, workspace left.

Nothing found and nothing open from last week: the whole report is
`all clear` and the verdict line. Then
`sec-security-audit-workspace remove $(basename $ws)`. The very last line
is exactly one of

    SECURITY-AUDIT: all-clear
    SECURITY-AUDIT: fixed
    SECURITY-AUDIT: reported
    SECURITY-AUDIT: failed

Nothing after the line.
