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
| 3 | Boot counting | systemd-boot machines (amy joy nas som vit) fall back to the last good entry when a new generation never boots healthy. | on main, not yet deployed |
| 4 | Runtime watchdog | A local timer notices "I am cut off" (not an upstream outage) and escalates: restart units, restart the network, reboot. | on main, not yet deployed |
| 5 | External power-cycle | Out of scope for now. | not planned |

## Health

`selfheal health [--level deploy|local|boot] [--json]` (exit 0 = healthy):

- deploy (part 1): sshd active, listening on each configured port (one
  item per port, `ss -ltn`), every mesh daemon the machine runs active (derived from
  its config: zerotierone, yggdrasil; mycelium/tailscale where
  enabled), and at least one anchor answering ICMP or TCP 22 within 2 s.
  Anchors: edi, sgp and bam (minus the machine itself) at every overlay
  address the repo knows (`<m>.d` = yggdrasil, `<m>.wg-edi`, `<m>.wg-vault`
  from the clan services' /etc/hosts lines, zt-eu from
  `vars/shared/zerotier-ip-<m>-zt-eu`). Option `hyper.selfHeal.anchors`.
- local: sshd, a link up, and any default route's gateway answering
  (ICMP, or ARP for IPv4; v4 and v6, every uplink). Never looks past the
  gateway, so an upstream outage is not a local fault.
- boot (part 3): local where `hyper.selfHeal.bootHealth.requireGateway`
  is on; sshd alone on roaming laptops (amy, joy).

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

## Part 3: boot counting

`modules/nixos/self-heal/boot-counting.nix`, on every machine with
systemd-boot (amy joy nas som vit; GRUB on bam edi sgp and extlinux on
cm-pi have no boot counting in NixOS: there parts 1, 2 and 4 must do).
Options: `hyper.selfHeal.bootCounting.{enable,tries}` (default: on where
systemd-boot is, 2 tries), `hyper.selfHeal.bootHealth.{requireGateway,
timeout,interval,tangPeers}` (default: gateway required unless
`hyper.selfHeal.roaming`, 10 min, every 10 s, no Tang peers).

How systemd-boot counts (nixpkgs `bootCounting`, systemd 262):

1. The boot loader installer writes every NEW entry file as
   `nixos-<hash of its contents>+2.conf`. An entry whose contents already
   exist on the ESP keeps its file name, counter or not: a blessed entry
   stays blessed, a counting one keeps counting.
2. systemd-boot renames the entry it picks BEFORE it loads the kernel
   (`+2` -> `+1-1` -> `+0-2`) and sets `LoaderBootCountPath`. `loader.conf`
   says `preferred <the profile's entry>` and `default nixos-*`: an entry
   at `+0` is bad, so `preferred` skips it and `default` picks the newest
   entry that is not bad.
3. In stage 2, only on a counted boot, systemd-bless-boot-generator pulls
   in `systemd-bless-boot.service`, which waits for boot-complete.target
   and then drops the counter (`nixos-<hash>.conf`: blessed, never counted
   again). A blessed or uncounted boot runs neither.
4. `selfheal-boot-healthy.service` is `RequiredBy` + `Before`
   boot-complete.target (after network-online, sshd, selfheal-boot): it
   runs `selfheal boot-health`, which retries `selfheal health --level
   boot` (healthy twice, 1 s apart) for up to 10 min, counted on the
   monotonic clock from the gate's own start (after network-online and
   sshd; slow units elsewhere in the boot don't eat it, and a clock step
   by timesyncd can't cut it short). Healthy: the boot is blessed. Still unhealthy: the unit fails, the boot is not blessed, and
   it restarts the machine so systemd-boot spends the next try, but only
   when all of these hold:
   - the boot is try-counted: `LoaderBootCountPath` set and
     `systemd-bless-boot status` = indeterminate or dirty;
   - this boot spent one of the `tries` (done <= tries). An entry at `+0`
     is only booted again when every entry is bad; restarting would pick
     it again, so it stays up;
   - no `selfheal hold` (logged as `boot-unhealthy ... reboot=no why=held
     until ...`) and no switch running (`why=a switch is running`; the
     restart itself runs under the CLI's lock, right after this check);
   - on vit and som, a Tang peer answers (`bootHealth.tangPeers`, below).

   When one of these blocks, the gate fails once and is not retried: the
   boot stays up, unblessed, with one try spent, and nothing restarts it
   (the deploy guard, part 4 or a person still can). A blessed or uncounted
   entry never restarts from here, so there is no loop: at most 2
   self-restarts per boot entry (a rollback writes a fresh entry for the
   same system), then the previous entry, which is blessed.
5. `selfheal_boot_fallback` = 1 (selfheal-boot.service writes it at boot,
   the deploy guard's pre-switch check rewrites it) while the system
   profile's boot entry is bad (`+0-N`: the next boot would take an older
   entry) or, at boot, while the booted system is not the profile (fell
   back, or someone picked an older entry). Warning "Booted an older
   generation" in the digest after 30 min. `selfheal_boot_health_ok` holds
   the last gate result.
6. A live `switch` to the system profile whose entry is bad gives that
   entry fresh tries: the pre-switch check renames `nixos-<h>+0-N.conf` to
   `nixos-<h>+2.conf` (event `boot-entry-retry`). The operator just chose
   that system again; without the rename the builder keeps the bad name
   (same contents), and the next boot would silently take the older entry.
   The new name comes only from the entry's own file name.

What it does not cover: a generation that never reaches the gate, e.g.
one that ends in emergency.target (a failed mount without `nofail`, like
nas's pool11) or hangs before multi-user. PID 1 is alive there, so the
hardware watchdog does not fire either; only a power-cycle spends the next
try. The `link` item counts any interface that is up (on som the
container veths always are); the real signal is the gateway check.

### With clan and the deploy guard

- clan runs `nix-env --set <new>` (a new generation number, so new entry
  contents), then `switch-to-configuration boot`: the new entry is `+2`
  and `preferred`. The live `switch` that follows touches neither entry:
  systemd-bless-boot has `restartIfChanged = false`, and the running boot
  was decided (blessed, or uncounted) at its own boot. The new
  generation's entry keeps `+2` as long as the machine does not restart;
  that is right, it never booted. The next boot spends its first try.
- If the live switch hangs and someone (or part 4) power-cycles, the new
  generation gets 2 boots to come up healthy before the previous entry
  boots. The 2026-11-19 failure boots fine from cold, so it is blessed.
- The deploy guard's rollback runs `nix-env --set <prev>` and
  `<prev>/bin/switch-to-configuration boot`. That is a new generation
  number with prev's system, so new entry contents (the entry carries the
  generation number): prev comes back as a
  fresh `+2` entry and is blessed on its first boot (prev booted healthy
  before). The older entry of the same system stays blessed. That is
  right: a prev that suddenly can't boot healthy (hardware) falls back
  further, to that older blessed entry.
- A deploy refused by the rollback flag has set the profile but not the
  boot entry: nothing changes for boot counting.

### Encrypted roots (vit, som) and roaming laptops

- vit (LUKS root, tang on som, initrd Wi-Fi + ssh) and som (ZFS root,
  tang on vit, clan-unlock): systemd-boot spends the try when it picks the
  entry, before the kernel. Waiting at the unlock, however long, costs
  nothing more. The gate is a stage-2 unit (the generator skips the
  initrd), so it only starts once the root is unlocked; its 10 min start
  only then.
- Each power-cycle while stuck at the unlock costs one try. A new
  generation power-cycled twice at the unlock is bad (`+0-2`) and the next
  boot takes the previous entry. That does not matter: the older
  generation needs the same key, so it waits at the same prompt, and once
  unlocked it is blessed. The bad entry stays bad: a deploy of a new
  generation writes a fresh `+2` entry; a redeploy of the same system
  gets fresh tries through the rename in 6. A blessed entry is never
  affected. The test covers exactly this.
- vit and som hold each other's Tang key (Dave's rule: never both down in
  the same window). If both restarted together (same bad generation
  deployed to both, or a casa power cut followed by a gateway that comes
  up late), each initrd would wait for the other's Tang, and
  `clan-unlock` goes through the other machine too: a person at a console
  would be needed. So on these two the gate restarts only while at least
  one Tang peer answers TCP 7654 at its link-local address
  (`hyper.selfHeal.bootHealth.tangPeers`: vit -> som `fe80::7a6e:1` on
  wlo1, som -> vit `fe80::7a6e:2` on br0, the stage-2 LAN interfaces; set
  in their configuration.nix). A peer that answers is up and unlocked, so
  it can unlock us after the restart. A peer that answers may itself be
  about to restart; so the gate first stops its own Tang
  (`tangd.socket`), looks again 15 s later and only then restarts: of two
  gates expiring together, neither restarts (both stay up). If the peer
  rule is the only blocker, the gate polls the peer every 30 s for up to
  1 h (a peer whose Wi-Fi or unlock comes late after a power cut), logged
  once as `boot-unhealthy-waiting`, and re-checks health each time: a
  boot that recovers meanwhile (the gateway back after the power cut) is
  blessed (`boot-healthy after=tang wait`), never restarted. A hold set
  before the gate decides, a running switch and the tries cap still win
  (a hold set during the 15 s withdraw takes effect only after it). The
  withdraw is skipped where no tangd.socket exists (not-found or masked; any other load state blocks); if our Tang can't
  be stopped, or comes back during the withdraw, the gate does not
  restart and keeps polling. Health is checked once more at the end of
  the withdraw: a boot that recovered meanwhile is blessed
  (`after=tang withdraw`). Our Tang is started again whenever the machine
  stays up (also on an error, on a SIGTERM of the gate during the
  withdraw, or when `systemctl reboot` fails: event
  `boot-reboot-failed`); deliberately not via ExecStopPost, which would
  bring it back during our own shutdown. While the gate waits (up to
  ~75 min), `systemctl is-system-running` reports `starting`.
  No peer by then: the boot stays up, unblessed
  (`why=no tang peer answers ...`). Options
  `bootHealth.{tangPollInterval,tangPollTimeout,tangWithdraw}`. An
  assertion requires tangPeers wherever `hyper.tangClient.servers` is
  set.
  The flip side: a generation that breaks the LAN on vit or som can't
  reach the peer either, so the gate never restarts it (a power-cycle,
  part 4 or a person must); on vit (sshd-only gate) such a generation is
  even blessed.
- Policy by class (`bootHealth.requireGateway`):

  | Machines | Gate | Why |
  |---|---|---|
  | nas, som | sshd + link + gateway | always on, wired or Wi-Fi; no gateway at boot = the new generation broke the network |
  | vit | sshd only, for now (`requireGateway = false` in its configuration.nix) | its Wi-Fi is a NetworkManager profile outside the repo; if it is user-owned (`permissions=user:...` or an agent-owned PSK) there is no gateway until Dave logs in, and every boot would spend a try. Turn it on once `nmcli -f NAME,TYPE,AUTOCONNECT c` and the profile's `permissions=`/`psk-flags=` show it comes up without a login. |
  | amy, joy (`hyper.selfHeal.roaming = true` in their configuration.nix) | sshd only | laptops boot offline on purpose (train, no Wi-Fi yet); sshd up proves the system came up |

  The repo has no laptop tag (amy and vit import `laptop.nix` for battery
  behaviour, but vit is always on), hence the explicit `roaming` option,
  which part 4 can reuse for its report-only mode. Under requireGateway a
  machine without any default route fails the gate ("no default route");
  with several uplinks any one gateway answering is enough.

### Operating it

- `bootctl list` shows the counters (`tries: 1 left, 1 done`);
  `$(dirname $(readlink -f $(command -v systemctl)))/../lib/systemd/systemd-bless-boot status`
  prints good/bad/indeterminate/clean for the running boot.
- Keep a broken boot up to debug it: `selfheal hold <minutes>` (it is
  persistent; set it before restarting into the new generation), or pick
  another entry in the boot menu.
- `bootctl set-default` does not beat `preferred`; the next deploy (any
  `switch-to-configuration boot`) writes `preferred` anew.
- Logs: `journalctl -u selfheal-boot-healthy`; events `boot-healthy`,
  `boot-unhealthy`, `boot-fallback` in `/var/lib/selfheal/log.jsonl`.

### Test

`checks.x86_64-linux.self-heal-boot-counting`
(`modules/nixos/self-heal/boot-counting-test.nix`, one systemd-boot VM
with generations A healthy, B without sshd, C with an initrd unit that
stands in for an unlock wait): (a) A is blessed on its counted first
boot; (b) B restarts itself twice (`+1-1`, `+0-2`), then A boots, stays
blessed and never restarts, even with sshd stopped; the deploy guard's
rollback path (`nix-env --set A` + `boot`) gives A a fresh `+2` that is
blessed; a hold keeps an unhealthy B up and unblessed; (c) two
power-cycles at the unlock stand-in mark C bad and the older A boots; a
single slow unlock costs one try and C is blessed; roaming: `--level
boot` passes on sshd alone without a default route, `--level local` and
the fleet default do not; a generation with a Tang peer (node `peer`,
TCP 7654): the peer answers when the gate expires but goes away while
the gate has withdrawn its own Tang (two simultaneous gates), so it stays
up unblessed and its Tang comes back; on the next try the peer comes back
during the polling and it restarts; a boot whose sshd comes up during the
Tang wait is blessed on the same boot, before the returning peer could
trigger a restart; a generation
with the uplink down fails on "no default route" and restarts; a running
`clan-switch-*` unit blocks the restart (`why=a switch is running`); a
`switch` to the profile renames its bad entry back to `+2`.

## Part 4: runtime watchdog

`modules/nixos/self-heal/watchdog.nix` (options `hyper.selfHeal.watchdog.*`),
code in `selfheal.py` (section "runtime watchdog"). The timer
`selfheal-net-watchdog.timer` runs `selfheal watchdog tick` every minute
(first 2 min after boot). One tick probes in parallel, with the health
checks above (no second implementation):

- sshd: active and listening on its ports (`check_sshd`)
- S: sshd plus every mesh daemon active (`check_mesh`)
- G: a default route's gateway answers (`check_gateway`); if one exists
  but is silent, a LAN neighbour: an all-nodes ping (`ff02::1`) on the
  default route's interface answered by an address that isn't ours, or the
  tang peer's link-local address (`watchdog.lanPeers`). A neighbour counts
  only if it came in through a physical port with carrier: on a bridge,
  its MAC must sit on a real NIC member in `bridge fdb` (som's br0 also
  carries its nspawn containers' veths, which answer even when enp6s0 is
  dead). No default route at all (lease/RA lost, a config error) is our
  own fault: link, whatever the LAN says.
- I: one of `hyper.selfHeal.internetProbes` answers ICMP or TCP 443
- M: one overlay anchor answers (`check_anchors`, the deploy guard's anchors)

### Reachable

"Reachable by us" = sshd runs and listens AND M ok (some overlay,
yggdrasil, zerotier or wireguard, reaches an anchor: edi, sgp, bam). That
is how we get in; every path in we use is an overlay, so the brief's "I ok
and some path in" comes to the same. Each tick sorts the result into one
state (first match wins):

| State | Condition | Meaning | Action (modes repair and full) | Counts towards the reboot |
|---|---|---|---|---|
| ok | sshd, S, M ok | reachable | end the incident | - |
| services | sshd down or not listening | we can't get in | `reset-failed`, then start sshd, the mesh units and multi-user.target (the deploy guard's restore) | yes |
| degraded | sshd and M ok, a mesh daemon down | reachable, one overlay fewer | the same restore | never (warning alert after 1 h) |
| link | M down, gateway silent (or no default route), no LAN neighbour answers | our own link (vit's wedged Wi-Fi) | after 5 min: restart the uplink (NetworkManager, else wpa_supplicant; systemd-networkd); on vit first reload the Wi-Fi driver (`hyper.initrdWifi.reloadDriver`, shared with initrd-wifi-watchdog) | yes |
| noroute | M down, no default route, but a LAN neighbour answers on the uplink remembered from the last route | our DHCP/RA, or a router dead longer than its DHCP lease (~48 h; the RA route expires after 30 min) | the same uplink restart as link | never: a reboot can't bring back a lease from a dead router, and every healthy LAN machine would reboot daily |
| upstream | M down, and gateway silent but a LAN neighbour answers (the router is dead), or gateway ok and internet down | casa's router or ISP | nothing, ever: log + metric | never |
| anchors_down | M down, G and I ok, anchors silent on their public addresses (TCP 22) too | the anchors are down, not us | nothing | never |
| mesh | M down, G and I ok, the anchors answer on their public addresses (or none are known) | our overlays are wedged | restart the mesh daemons | only after `meshRebootAfter` (2 h) + up to `meshRebootJitter` (30 min, fixed per host) AND two mesh restarts: an anchor-side overlay outage (a bad zerotier/yggdrasil deploy on edi/sgp/bam) would otherwise reboot the whole fleet |

Repairs run only after a fault was seen on 2 ticks in a row
(`repairAfterTicks`: a deploy's stop window is shorter), each step at most
every 10 min, and never while a switch runs or `selfheal hold` is on (one
`watchdog-repairs-held` log line). The incident starts at the first
counted tick and ends at the first tick that isn't (ok, degraded,
noroute, upstream, anchors_down), so an upstream outage never adds to it.
Known residual of noroute: a route lost through our own fault while the
router lives and the LAN answers is restarted every 10 min but never
rebooted (planned: ask the remembered gateway directly, ARP/ND, and call
it link if it answers). A machine with no remembered uplink (fresh
state) only checks the tang peer, else link. A link
that flaps back for one tick every < 30 min therefore never reaches the
reboot: "reachable sometimes" is reachable. Unreachable (counted) for
30 min (`rebootAfter`) in mode full: reboot if every gate passes; a tick
that just ran a repair waits one more tick. If the running system came
from a live switch less than 24 h ago that the deploy guard never
confirmed (a pending deploy, or `/run/current-system` !=
`/run/booted-system` without a confirm), the deploy guard's rollback runs
instead, back to the last confirmed system (else the booted one). If
`systemctl reboot` can't be queued, the watchdog logs `reboot-failed` and
forces it (the same tail as the deploy guard's rollback).

### Gates

All must pass; the first that blocks is logged (`watchdog-reboot-blocked
gate=...`, `selfheal watchdog status`, metric
`selfheal_watchdog_reboot_blocked{gate}`):

1. boot-grace: up for at least 30 min.
2. daily-cap: no watchdog reboot or rollback in the last 24 h
   (`/var/lib/selfheal/watchdog/last-reboot.json`; a stamp from the future,
   a bad RTC, is ignored and logged).
3. switch: no clan-switch-*/clan-boot-* unit, no switch-to-configuration
   process, younger than `switchHungAfter` (the deploy guard's maxExtend,
   1 h). An older one is hung (a switch with the guard disarmed:
   NIXOS_NO_CHECK, by hand, arm-failed): it no longer holds repairs or the
   reboot, logged once as `switch-hung`.
4. hold: no `selfheal hold` (the same hold as the deploy guard's).
5. tang peer (vit <-> som, below).
6. seat (below).

### vit and som: never both in the same window

vit and som hold each other's tang key (`watchdog.tangPeer`, derived: we
run a tang server and our first tang server is the peer). Rule: they never
reboot in the same window.

1. A tick that wants to reboot first PUBLISHES its intent
   (`/run/selfheal/watchdog-peer.json`: rebootPending, intentAt, rebooting),
   then asks the peer, and waits at least one tick after publishing
   (gate `peer-handshake`), so a peer that starts wanting at the same time
   sees our intent before either acts.
2. Peer booted < 30 min ago (`peer-recent`), or committed to its reboot
   (`peer-rebooting`): refuse. Never overridden; both are bounded.
3. Both want to: the earlier intent goes first, a tie the lower name
   (som before vit). Both compare the same two published numbers, so they
   agree; the winner re-queries once before committing. The other then
   sees "rebooting", then the peer down or freshly booted.
4. Peer unreachable (`peer-down`, also no key yet): refuse until our own
   outage passes `peerOverrideHours` (6 h); vit (later in name order)
   waits `peerStaggerMinutes` (60 min, must exceed peerRecent + a boot)
   longer, so after a shared outage som goes at 6 h, vit sees som down or
   just booted and can only go at 7 h, after som is back.

How we learn the peer's state: ssh to the peer as root with a dedicated
key (clan var `selfheal-peer-ssh`, shared by vit and som) whose
authorized_keys line is
`command="selfheal watchdog peer-info",from="fe80::*%<our tang interface>,<peer's yggdrasil address>",restrict`
(sshd matches a link-local client with its `%scope`: a CIDR like
`fe80::/10` never matches, the wildcard does):
it can only print `{"host", "bootId", "uptime", "rebootPending",
"intentAt", "rebooting"}`. The host key is pinned from the peer's clan
openssh var (an assertion refuses a production build without it), the
port is the peer's first sshd port. Addresses, in order: the peer's fixed
tang link-local address on our LAN interface (works with the internet and
every overlay down; vit and som share Dave's LAN), then `<peer>.d`.
Rejected: an unauthenticated endpoint (anyone on the LAN could fake "peer
just booted" and hold our reboot off) and "tang answers" (says up, not
since when).

Trade-offs (Dave's rule; open question filed by the lead): if WE are cut
off we probably can't reach the peer either, so we wait the 6 h override
(vit 7 h). A peer-down override reboot needs the other's tang to unlock:
if the LAN itself is what's broken (both see each other down for > 7 h),
som reboots at 6 h and waits in its initrd for vit's tang, vit reboots at
7 h and waits for som's: both then need `clan-unlock` by hand. Before
part 4 both simply came back when the LAN did. The 30 min/1 h stagger
only prevents the same window, not this.

### Seat warning (vit, som)

`watchdog.seatWarning` (default: mode full and a display manager). When
every other gate passes and a local user session is on seat0 (logind:
Seat=seat0, Remote=no; ssh sessions and agents never count), the tick
starts a 5 min countdown (`countdown`) instead, writes
`selfheal: <host> is unreachable from the network and will reboot in 5:00 — cancel once: ...`
to every terminal (wall) and the session's tty on each tick, and sends a
critical desktop notification to the session's user (notify-send on their
session bus, with a Cancel action; noctalia's notification server
advertises `actions`). A person at the seat may cancel once per incident:

- the notification's "Cancel the reboot" action, or
- `selfheal cancel` in a terminal on the seat (any user, no sudo). It talks
  to `/run/selfheal/cancel.sock`; the socket's service reads the caller's
  pid (SO_PEERCRED) and accepts only a caller in a seat0 session scope with
  Remote=no, or in an `app-*` scope/service of the user manager of a user
  with an active local seat0 session (what niri and the launchers start
  terminals in). ssh, `systemd-run --user` (run-*) and agents' own units
  are refused. Residual: a process of the seat user running in an app-*
  unit (e.g. `systemd-run --user --unit=app-x`, possible over ssh) still
  passes; one cancel costs 30 min, once per incident.

After a cancel it warns again 30 min later (`rearmAfter`); that warning
can't be cancelled, and the reboot follows when its countdown ends. No
session on the seat: no warning, the reboot follows at once.

### Modes

| Machine | Mode | Why |
|---|---|---|
| amy, joy | report | `hyper.selfHeal.roaming`: they roam and go offline on purpose; probes + metrics only |
| nas, cm-pi, bam | full | unattended, or at a site without a person |
| vit, som | full + seat warning + tang peer | Dave's rule: unreachable must reboot, even while used |
| edi, sgp | full | Dave's rule covers every machine that would otherwise lock us out. Both have a provider console, but that needs a person at a browser; the gates (30 min, once a day, never for upstream, mesh only after 2 h) make a wrong reboot of a cloud box cheap, while a missed one costs pocket-id and grafana (edi) or som's IPv4 (sgp) until someone logs in. |

`mode = "repair"` (restart steps, never a reboot) stays available per
machine.

### Commands

| Command | What |
|---|---|
| `selfheal watchdog status [--json]` | state, time cut off, blocking gate, repairs held, warning, last watchdog reboot, action counts |
| `selfheal cancel` | cancel a seat warning once (only from the seat) |
| `selfheal hold <minutes>` | holds the watchdog's repairs AND its reboot (and the deploy guard) |
| `selfheal watchdog tick` | one tick by hand |

Metrics (`/run/selfheal/watchdog.prom`): `selfheal_watchdog_state{state}`,
`selfheal_watchdog_actions_total{action}` (restore, mesh_restart,
uplink_restart, warn, cancel, reboot, rollback; kept across reboots),
`selfheal_watchdog_unreachable_seconds`,
`selfheal_watchdog_last_reboot_timestamp_seconds{kind}`,
`selfheal_watchdog_reboot_blocked{gate}`, `selfheal_watchdog_mode{mode}`.
Alerts (`modules/nixos/monitoring-alerts.nix`): "Watchdog rebooted a cut-off
machine" (critical, for 2 h after it), a watchdog rollback pages as "Deploy
rolled back" (its flag), "Watchdog repaired a machine" and "Mesh daemon
down (reachable)" (warnings, digest), "Watchdog reboot blocked" (warning,
35 min, seat gates excluded).

New clan vars generator: `selfheal-peer-ssh` (shared by vit and som,
prompt-free): run `clan vars generate vit` before their first deploy.

## Per-machine policy

From the proposal, adjusted by Dave's decisions (2026-11-20).

| Class | Machines | Deploy guard | HW watchdog | Boot counting | Runtime watchdog |
|---|---|---|---|---|---|
| Remote, unattended | nas | yes | if present | yes, gate on sshd + gateway | full, reboot allowed |
| Always-on desktops | vit, som | yes | yes (iTCO / SP5100) | yes, gate after the unlock: som sshd + gateway, vit sshd (Wi-Fi unproven); restarts only while the other's Tang answers (never both in the same window) | full; on-screen warning with a ~5 min countdown, cancellable once; never both in the same window (mutual tang) |
| Wired/cloud servers | bam, edi, sgp | yes | bam, edi (sgp has none) | no (GRUB) | full: restart steps, reboot when unreachable |
| Home Pi | cm-pi | yes | yes (StarFive) | no (extlinux) | full, reboot allowed |
| Laptops | amy, joy | yes | joy yes; amy off (suspend) | yes, gate on sshd only (they boot offline) | metric only, no actions |

Binding rules (part 4 implements them): an unreachable machine reboots
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

`checks.x86_64-linux.self-heal-net-watchdog`
(`modules/nixos/self-heal/watchdog-test.nix`): router + upstream nodes,
ticks by hand with a fake clock (`watchdog.testClockFile`). (a) upstream
outage (the router drops the anchor and the internet probe) for 2 simulated
hours: state upstream, no action. (h) the router dead but a LAN neighbour
answers: upstream, also through a bridged uplink (node brh); our own link
dead: link, uplink restart after 5 min; brh's NIC wedged while a local
container on its bridge still answers ff02::1: link. (j) no default route
while the tang peer answers on the LAN: link.
(b) stopped sshd + mesh stand-in are restarted on the 2nd bad tick; a mesh
stand-in that stays dead while the anchor answers is "degraded" for 2 h,
never a reboot; an unrestartable sshd reboots once (an ssh session open
meanwhile), then the boot grace and the daily cap block. (f) a running
clan-switch unit and `selfheal hold` hold repairs and the reboot; a switch
older than switchHungAfter doesn't (event switch-hung once). (g) the
mesh state: mesh restarts, counted only after meshRebootAfter and two
restarts. (c) a tty login on seat0: countdown, `selfheal cancel` over ssh
and from the seat user's manager over ssh refused, from the seat accepted
once, the re-armed warning refuses it, then the reboot. (d) tang peer:
handshake tick, down -> refused, back but just booted -> refused even after
7 h, down after 6 h -> reboot; the forced command answers peer-info only.
The peers query each other over their eth1 link-local addresses with
`from="fe80::*"`, the path vit and som use.
(i) both peers cut off at once and ticked concurrently: never both
"rebooted" in any round, exactly one goes, the other waits for the peer-down
override (+60 min for the later name). (e) roaming laptop: report only.
