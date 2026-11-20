# Self-heal

Machines that drop off the network get themselves back without a person
at the console. Trigger: on 2026-11-19 a live switch stopped sshd and every
mesh daemon on nas and vit and never started them again; only a
power-cycle brought them back. Code: `modules/nixos/self-heal/` (one
option namespace `hyper.selfHeal.*`, one state dir `/var/lib/selfheal`,
one CLI `selfheal`), enabled on every machine but the installer by
`modules/nixos/common.nix`.

## Parts

| # | Part | What it does | Status |
|---|---|---|---|
| 1 | Deploy guard | Every live switch must leave the machine reachable; otherwise restore stopped units, then roll back to the previous generation and reboot into it. | on main, not yet deployed |
| 2 | Hardware watchdog | Systemd pets `/dev/watchdog`; a hung kernel or PID 1 reboots. | on main, not yet deployed |
| 3 | Boot counting | systemd-boot machines (amy joy nas som vit) fall back to the last good entry when a new generation never boots healthy. | planned |
| 4 | Runtime watchdog | A local timer notices "I am cut off" (not an upstream outage) and escalates: restart units, restart the network, reboot. | planned |
| 5 | External power-cycle | Out of scope for now. | not planned |

## Health

`selfheal health [--level deploy|local] [--json]` (exit 0 = healthy):

- deploy (part 1): sshd active, listening on each configured port (one
  item per port, `ss -ltn`), every mesh daemon the machine runs active (derived from
  its config: zerotierone, yggdrasil, hyprspace; mycelium/tailscale where
  enabled), and at least one anchor answering ICMP or TCP 22 within 2 s.
  Anchors: edi, sgp and bam (minus the machine itself) at every overlay
  address the repo knows (`<m>.d` = yggdrasil, `<m>.wg-edi`, `<m>.wg-vault`
  from the clan services' /etc/hosts lines, zt-eu from
  `vars/shared/zerotier-ip-<m>-zt-eu`). Option `hyper.selfHeal.anchors`.
- local (later parts): sshd, a link up, the default gateway answering.
  Never looks past the gateway, so an upstream outage is not a local fault.

A ping alone is not enough: on nas the link and kernel WireGuard kept
running while sshd and the mesh daemons were gone.

## Part 1: deploy guard

1. clan runs `nix-env -p /nix/var/nix/profiles/system --set <new>`, then
   `switch-to-configuration boot`, then `switch`. The guard is a
   `system.preSwitchChecks` entry of the NEW system. For `switch` to a
   system other than the running one it records the running system
   (`/run/current-system`; the profile already points at the new one) and
   the deploy health as a baseline (a 2-3 s probe), and arms a transient
   timer, `selfheal-deploy-guard-<token>.timer`, 15 min out. Transient
   units live in /run/systemd/transient; switch-to-configuration only
   touches units in /etc/systemd/system, so the switch can't stop the
   timer (a `daemon-reexec` keeps it too). The check never fails the
   switch because of its own errors.
2. When the timer fires, only the items that were healthy at arming are
   judged (`selfheal status` lists them): a unit that was already dead, or
   anchors unreachable on an offline laptop, can't make the switch look
   bad.
   - healthy: confirmed. If a switch still runs (a clan-switch-*/clan-boot-*
     unit or a switch-to-configuration process), it re-checks every 5 min
     and confirms once the switch is done (at most 60 min after arming),
     since a long switch can still stop units in its later phases.
   - a hold re-arms for its expiry and does nothing else.
   - only the anchors fail (sshd and the mesh daemons fine): it is an
     upstream outage only by Dave's definition, "the gateway answers, the
     internet AND the mesh don't":
     - the own link and default gateway must answer, and
     - NOT (the internet answers, `hyper.selfHeal.internetProbes`:
       1.1.1.1, 9.9.9.9 and two IPv6 resolvers, ICMP or TCP 443, AND the
       anchors answer TCP 22 on their public addresses, `anchorsPublic`: sgp's
       38.89.142.76 and the first two (alphabetical) of edi's ACME names,
       derived from the repo; an empty list is an eval warning).
       Internet up and the anchors publicly reachable means this machine's
       overlays are broken (firewall, routes, mesh config): a local fault,
       restored and rolled back below. Internet up but the anchors silent
       on every address means the anchors are down: upstream.
     An upstream outage (casa uplink, edi+sgp+bam down) re-checks every
     5 min and is confirmed after 60 min (`how=upstream`); never a
     restore, rollback or reboot.
     Roaming machines (`hyper.selfHeal.roaming`: amy, joy) skip the
     link/gateway/internet tests: as long as sshd and the mesh daemons run,
     failing anchors are the laptop being offline (no Wi-Fi in range, a
     captive portal). A switch that stops sshd or a mesh daemon on a laptop
     is still rolled back; an overlay-only cut-off on a laptop (firewall or
     mesh config, daemons running) is never undone.
     Accepted gaps of this definition (no false reboot, but no rollback):
     - a switch that breaks the resolver: edi's public names don't
       resolve, so on sgp (whose only public anchors they are) an overlay
       cut-off plus a broken resolver counts as upstream. sgp stays
       reachable on its public IP, port 21, while sshd runs.
     - a switch that breaks this machine's own internet egress (default
       route, NAT, nft output) while the gateway still answers ICMP counts
       as upstream and is confirmed after 60 min.
   - otherwise restore at once, even while a switch still runs (it is
     cheap; if the switch later completes, the units started early may run
     their old definition until restarted, which a restart of them or the
     next deploy fixes): `systemctl start multi-user.target`, sshd and the mesh
     units (after `reset-failed`), then re-check for 2 min (at least 5
     checks, on the monotonic clock, so a suspend inside the window does
     not cut it short).
   - still unhealthy: if a switch still runs, wait for it in 5 min steps
     up to 60 min after arming. Then roll back: kill the hung switch,
     `nix-env -p /nix/var/nix/profiles/system --set <prev>`,
     `NIXOS_NO_CHECK=1 <prev>/bin/switch-to-configuration boot`, write
     the rollback flag, `systemctl reboot`. If prev is gone or its boot step
     fails it reboots anyway (into the new generation's entry): a fresh boot
     beats staying locked out. The flag says so. A reboot whose stop jobs
     hang is forced by reboot.target's own 30 min job timeout.
3. A pending deploy survives a reboot: at boot it is re-armed if the new
   system booted, dropped if another one did.
4. After a rollback, `/var/lib/selfheal/deploy-guard/rolled-back` blocks
   every `switch` and `boot` to the machine (clan's deploy fails at its
   first step) with one line:
   `selfheal: <host> rolled back <from> -> <to> at <time> (<reason>); inspect, then run `selfheal clear` on <host> (if not on PATH: <python> <selfheal.py> --config <json> clear)`.
   Metric `selfheal_deploy_guard_rolled_back{reason}` = 1 pages Telegram
   ("Deploy rolled back", `modules/nixos/monitoring-alerts.nix`), repeated
   daily until `selfheal clear`.
   A refused deploy has already set the profile (clan's `nix-env --set`
   runs before the refused boot step): the boot entry stays on the rolled
   back system, but `nix-env -p /nix/var/nix/profiles/system --rollback`
   (or the next deploy) puts the profile back.

First rollout gap: until a machine has run one guarded generation, the
system a rollback returns to predates the guard. After such a rollback
there is no `selfheal` on PATH (use the full command from the block line),
no selfheal-boot.service and no selfheal.alloy, so the page most likely
never fires (the metric written before the reboot lands in /run and is
lost), and deploy-parallel.sh sees exit 127 and deploys; clan then fails
at its boot step with the block line. Watch the first guarded deploy of
each machine by hand.

`deploy-parallel.sh` (fleet-change-delegation skill) skips a blocked
machine (`<m> BLOCKED-ROLLED-BACK <reason>`) and runs `selfheal confirm`
after each deploy, so a healthy machine is confirmed at once instead of
after 15 min.

Also tested (same check): an overlay-only cut-off (gateway, internet and
the anchor's public address answer) is rolled back; a roaming machine
without any route is confirmed how=upstream; a healthy machine waits for
a still running switch before it confirms. On the laptops (amy, joy:
`hyper.selfHeal.roaming`) being offline never rolls back; only a stopped
sshd or mesh daemon does.

### Commands (root, on the machine)

| Command | What |
|---|---|
| `selfheal status [--json]` | pending deploy, hold, rollback flag, last actions |
| `selfheal status --blocked` | prints the block line and exits 3 if the flag is set |
| `selfheal confirm` | runs the deploy health check (items healthy at arming); disarms if healthy |
| `selfheal confirm --force` | disarms without checking |
| `selfheal hold <minutes>` | no restore, no rollback until then (max 24 h); for deliberate cut-off experiments |
| `selfheal hold 0` / `selfheal release` | end the hold; a pending deploy is assessed 5 min later |
| `selfheal clear` | remove the rollback flag: deploys allowed again |
| `selfheal health` | the health check above |
| `selfheal deploy-guard arm [toplevel]` | arm by hand (e.g. after a `NIXOS_NO_CHECK=1` switch) |

Logs: `journalctl -u 'selfheal-*'` (the arming: the clan-switch-* unit's journal), `/var/lib/selfheal/log.jsonl`.

### NIXOS_NO_CHECK

`NIXOS_NO_CHECK=1` (clan forwards it) skips every pre-switch check,
the guard's included: nothing is armed, and a rollback flag does not block.
Use it only when you mean "no guard"; `selfheal hold` is the normal way to
keep a deliberate cut-off.

## Part 2: hardware watchdog

`modules/nixos/self-heal/hardware-watchdog.nix` sets
`RuntimeWatchdogSec=30s` and `RebootWatchdogSec=10min` (systemd's
default, already in effect; pinned so it is explicit) (options
`hyper.selfHeal.hardwareWatchdog.{enable,runtime,reboot}`). systemd pings
the device every 7.5-15 s from its main loop; if the kernel or PID 1 hangs
for 30 s the board resets the machine. PID 1 doesn't ping while it
re-execs or reloads during a switch: <= 3.3 s on every machine but som,
where it took 25 s (2026-11-19), so som runs 2 min. It only catches full
hangs, never "sshd stopped".
Where no device exists systemd logs it and carries on.

| Machine | Device | Setting |
|---|---|---|
| bam | SP5100 TCO (live, 2026-11-20) | on |
| som | SP5100 TCO (live) | on, **2 min** (re-exec/reload took up to 25 s) |
| edi | iTCO_wdt (live) | on |
| cm-pi | StarFive (live, max 357 s) | on |
| vit | iTCO (already had 30 s; now from the module) | on |
| joy | Intel 13th gen (Framework 12): iTCO expected; offline, unchecked | on |
| nas | Intel: iTCO expected; offline, unchecked | on (harmless without a device) |
| sgp | none (Proxmox VM without i6300esb) | on, inert; would need the provider to add a virtual watchdog |
| amy | AMD FCH (`i2c_piix4` in facter.json): SP5100 TCO | **off**: sp5100_tco has no suspend hooks, so in s2idle nobody pings it and it could reset amy mid-sleep. Enable after a suspend test on amy. |

On first deploy check: `systemctl show -P RuntimeWatchdogUSec` = 30s and
`cat /sys/class/watchdog/watchdog0/state` = active.

## Per-machine policy

From the proposal, adjusted by Dave's decisions (2026-11-20).

| Class | Machines | Deploy guard | HW watchdog | Boot counting | Runtime watchdog |
|---|---|---|---|---|---|
| Remote, unattended | nas | yes | if present | yes | full, reboot allowed |
| Always-on desktops | vit, som | yes | yes (iTCO / SP5100) | yes | full; on-screen warning with a ~5 min countdown, cancellable once; never both in the same window (mutual tang) |
| Wired/cloud servers | bam, edi, sgp | yes | bam, edi (sgp has none) | no (GRUB) | restart steps; reboot when unreachable |
| Home Pi | cm-pi | yes | yes (StarFive) | no (extlinux) | full, reboot allowed |
| Laptops | amy, joy | yes | joy yes; amy off (suspend) | yes | metric only, no actions |

Binding rules for the parts to come: an unreachable machine reboots
whether or not someone uses it (remote sessions never block it); an
upstream-only outage never triggers a reboot; at most one watchdog reboot
per day, none within 30 min of boot, none while a switch runs; vit and som
never reboot within 30 min of each other unless the own outage lasted
longer than a configurable number of hours.

## Tests

`checks.x86_64-linux.self-heal-deploy-guard` (`modules/nixos/self-heal/test.nix`):
systemd-boot VM plus an anchor node; switches like clan; a broken
generation is restored, rolled back and rebooted, then deploys are blocked
until `selfheal clear`; good switches confirmed by the CLI and by the
timer (across a `daemon-reexec`); a pending deploy survives a reboot; a
hold suspends the rollback; an upstream-only outage is confirmed
(how=upstream) without restore or reboot; a unit dead before the switch is
not judged; a hung clan-switch unit gets the restore at the first deadline
and the rollback only after maxExtend; a broken state dir does not block
the switch.

`checks.x86_64-linux.self-heal-hardware-watchdog`
(`modules/nixos/self-heal/hardware-watchdog-test.nix`): a VM with a
virtual i6300esb; systemd arms it with 30 s, and a PID 1 frozen with
ptrace gets the VM reset 15-50 s later (25 s measured; earlier would be a
panic, not the watchdog). Mutation check (module off, reset subtest only,
90 s wait): the reset never comes and the subtest fails.
