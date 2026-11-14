# nix `ca-derivations`: unsigned realisations from daemon clients

## What

With the experimental `ca-derivations` feature on, the nix-daemon accepts
build-trace entries ("realisations": derivation output -> store path) from
any client allowed on its socket, without checking a signature or that the
client is trusted. An unprivileged local user can therefore record a wrong
output for a content-addressed derivation that has not been built yet;
when another user (or the system) later builds that derivation, the daemon
uses the recorded path instead of building it. Input-addressed builds,
which is all the fleet does, are not affected; the risk exists only while
the feature is enabled on a shared daemon.

## Affected

Multi-user nix daemons with `ca-derivations` in `experimental-features`.
Seen with nix 2.35.4 (som); the daemon source of 2.34.9 (the other
machines) has the same unchecked path. Before this change, every fleet machine except
the installer had it on: `modules/nixos/common.nix` and, for amy/som/vit,
spaces' `modules/nixos/nix.nix` (nix >= 2.28). som is the one with untrusted
local users (hermes agents, space tenants).

On som the `Realisations` table held 256 rows (248 distinct derivations,
none signed), registered 2024-12-12 .. 2026-09-03, 236 of them on
2026-08-27. The outputs are a desktop/home-manager closure (firefox,
vscode + extensions, fish, python3.14 packages, systemd, glibc), a few nix
2.30/2.36 pre-release builds, and single entries (xonotic, jfk.wav, source).
The table was only read, not changed.

## Mitigation (hyperconfig)

- `modules/nixos/no-ca-derivations.nix` (imported by `common.nix`) removes
  `ca-derivations` from the final `nix.settings.experimental-features` with
  a `mkForce` that keeps every other module's features as they were
  (`impure-derivations` stays listed but is unusable without
  ca-derivations; nothing uses it).
- The same module asserts the feature is absent (also from
  `nix.extraOptions`); evaluating any machine fails otherwise and points
  here.
- `common.nix` and the standalone `guests/bam-inference/common.nix` no
  longer list it.
- Still to do at the source: spaces' `modules/nixos/nix.nix`
  (git.geninf.io/spaces/spaces-os) should stop adding it.

Existing realisations stay in som's DB. They are ignored while the feature
is off; delete them (or `nix store build-trace delete` on newer nix) before
ever turning it back on.

## Upstream status

Known and published:

- Advisory GHSA-jm6c-h95p-6qhj (2026-08-05, medium), "Unprivileged local
  users can poison CA derivation realisations via RegisterDrvOutput":
  https://github.com/NixOS/nix/security/advisories/GHSA-jm6c-h95p-6qhj .
  Vulnerable < 2.35 per the advisory (we see it on 2.35.4); fixed only on
  master, no stable backport. Workaround: don't enable `ca-derivations`.
- Fix: https://github.com/NixOS/nix/pull/16256 (merged 2026-08-03 on
  master); earlier attempt https://github.com/NixOS/nix/pull/16251 (closed).
- Issue https://github.com/NixOS/nix/issues/11393 "nix daemon does not
  check signatures when registering realisations" (open since 2024-08-31).

Reproducer: pending (Dave).

## Deploying

- nix.conf changes restart `nix-daemon.service` on switch, but with
  `KillMode=process` running per-connection workers keep their old
  settings (feature on) until their connection closes. The fix is
  complete on a machine only once no pre-switch `nix-daemon` worker is
  left (`ps -o pid,lstart,args -C nix-daemon`) or after a reboot.
- `guests/bam-inference` is a standalone flake without this guard and is
  switched separately: its line is removed, it takes effect on its own
  next deploy.
- Before the feature is ever turned back on (only once a fixed nix is
  in use): delete the old unsigned realisations from som's DB first.
