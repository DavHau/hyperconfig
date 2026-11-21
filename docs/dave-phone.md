# Dave's phone (Pixel 8a, GrapheneOS): mesh, night radio, Telegram push

Status doc. Goal: the phone stays reachable on the mesh without the
battery drain of ZeroTier on mobile data (67% -> 14% in one night:
ZeroTier's ~15 s heartbeat kept the LTE modem up, plus an idle hotspot
and an adb session).

| part | where | state |
|---|---|---|
| WireGuard peer `dave-phone` on wg-edi, mesh-only | `modules/nixos/wg-edi-phones.nix` | landed with `publicKey = null`; waits on the key from the phone |
| som on wg-edi (adb to the phone over WireGuard) | `modules/flake-parts/nixosConfigurations.nix` | separate change (side bookmark `phone-som-wg-edi`): needs som's two prompt-free wg-edi generators |
| Telegram push gateway `tg-push.davhau.com` + ntfy UnifiedPush ACL | `modules/nixos/telegram-push-gateway.nix`, `pkgs/aesgcm-proxy/` | landed (`*.davhau.com` already resolves to edi; ACME on first deploy) |
| Night Wi-Fi on / hotspot off | on the phone: Automation + Shizuku + Termux, `./dave-phone/hotspot-off-if-idle.sh` | apps installed and script tested; rules are Dave's taps |
| Telegram client: Mercurygram (replaces Forkgram) | on the phone | Dave installs, logs in, sets ntfy + gateway |
| ZeroTier off on the phone | on the phone | after WireGuard is proven |

## 1. WireGuard instead of ZeroTier

- App: the official WireGuard app `com.wireguard.android` is already on
  the phone (1.0.20260102, installed from download.wireguard.com: it
  updates itself). It is no longer on F-Droid; Aurora/Play carry the same
  app. Nothing to install.
- The phone's private key is generated in the app and never leaves the
  phone. Only the public key goes into `phones.dave-phone.publicKey` in
  `modules/nixos/wg-edi-phones.nix`; deploy edi (and every wg-edi member
  for the hosts entry).
- Address `fd73:d13c:e3:2700:8d88:f01:d622:4faf` (`dave-phone.wg-edi` on
  every wg-edi member). edi forwards the phone's traffic only to and from
  fd73:d13c::/40 over wg-edi (`wg-edi-phones` ip6tables chain); no
  internet, no zt-eu/ygg/LAN through edi.
- Split tunnel: AllowedIPs = `fd73:d13c::/40` only, so Android routes
  nothing else into the tunnel and keeps its normal internet path.
- Android runs one VPN at a time: turning the WireGuard tunnel on drops
  ZeroTier. Keep the ZeroTier app installed (zt-eu toggled off) until
  adb over WireGuard works from som, then remove zt-eu.

Taps (Dave, ~1 min):
1. WireGuard app -> `+` -> **Create from scratch**.
2. Name `wg-edi`. Private key: tap the **generate** icon. Addresses:
   `fd73:d13c:e3:2700:8d88:f01:d622:4faf/128`. DNS: leave empty.
3. **Add peer**: Public key `hvsfF4xvspwN5B5JZvpNdNDYEm8NcXDH1MABx5JKqQM=`,
   Endpoint `casa.bruch-bu.de:51821`, Allowed IPs `fd73:d13c::/40`,
   Persistent keepalive `120`. Save.
4. Open the tunnel, long-press the **Public key** of the interface ->
   copy, send it to the agent (it is public; the private key stays).
5. After the agent says "deployed": switch ZeroTier's zt-eu off, switch
   `wg-edi` on. Settings -> Network -> VPN -> WireGuard -> gear: **Always-on
   VPN** on (keeps it up across reboots), "Block connections without VPN"
   OFF (split tunnel).

Keepalive tuning: edi sends none to the phone; the phone's 120 s keeps
the carrier's NAT mapping. If som cannot reach the phone after a few
idle minutes on mobile data (the mapping expired), lower it 120 -> 90 ->
60; if it holds for a night, try 180, 240. Measure: from som, `ping -c1
dave-phone.wg-edi` after the phone has been idle for N minutes; on edi
`wg show wg-edi latest-handshakes` (a handshake renews at most every 2
min while traffic flows). Each keepalive is one 32-byte packet: at 120 s
the modem wakes ~30x/h instead of ZeroTier's ~240x/h.

adb over WireGuard (from som, once som is on wg-edi):
`adb connect [fd73:d13c:e3:2700:8d88:f01:d622:4faf]:5555` (classic tcpip
adb, set up while on Wi-Fi: `adb tcpip 5555`; survives until reboot).
`scripts/phone-adb-find.sh` takes the address as its argument. End every
session with `adb disconnect; adb kill-server`.

## 2. Wi-Fi on at night, hotspot off when idle

Open source only: **Automation** (`com.jens.automation2`, F-Droid, GPL),
**Shizuku** (`moe.shizuku.privileged.api`, Apache-2.0, GitHub release
v13.6.0, not on F-Droid) and **Termux** (already installed). Tasker,
Automate and MacroDroid are proprietary. Both new apps are installed.

- Wi-Fi on: Automation targets Android 9 (SDK 28), where apps may still
  switch Wi-Fi themselves; no extra rights. Android then joins saved
  networks only.
- Hotspot off: needs the shell uid (apps lost that in Android 10+).
  Shizuku runs a server as `shell`; Termux's `rish` reaches it;
  Automation calls a Termux script, which runs
  `/data/local/tmp/hotspot-off-if-idle.sh` (copy of
  `./dave-phone/hotspot-off-if-idle.sh`) through rish. The script stops
  the hotspot only with 0 clients and logs to
  `/data/local/tmp/hotspot-off-if-idle.log`. Tested as shell: rish
  answers `uid=2000(shell)`, stopTethering via `service call tethering 5`
  is accepted.
- After a reboot: Shizuku must be started again (Shizuku app -> Start
  via Wireless debugging, on Wi-Fi; v13.6 can start itself on a trusted
  Wi-Fi). Until then the hotspot rule fails silently (the Wi-Fi rule
  keeps working). Automation and the rules survive reboots.

Taps (Dave, ~5 min):
1. Shizuku: open it once (it shows "running": the agent started it over
   adb). Turn on "Start on boot (wireless debugging)" if offered.
2. Termux: run `termux-setup-storage` (allow), then
   `sh /sdcard/Download/termux-hotspot-setup.sh`. Shizuku asks to allow
   **Termux**: Allow. The script ends with `uid=2000(shell)`.
3. Automation: open, grant what it asks (notifications, exact alarms,
   battery unrestricted). Rules tab -> `+`:
   - **Night Wi-Fi on**: trigger Timeframe 22:30-22:31, every day;
     action "Set Wi-Fi" -> on.
   - **Night hotspot off if idle**: trigger Timeframe 23:00-07:00, every
     day, repeat every 3600 s; action "Start other program" -> by
     **service**, package `com.termux`, class
     `com.termux.app.RunCommandService`, action `com.termux.RUN_COMMAND`,
     parameters: String `com.termux.RUN_COMMAND_PATH` =
     `/data/data/com.termux/files/home/bin/hotspot-off-if-idle`, boolean
     `com.termux.RUN_COMMAND_BACKGROUND` = `true`.
   Nothing is scheduled by day. Turn the hotspot's own "Turn off hotspot
   automatically" back on too (Settings -> Network -> Hotspot): it is off.

## 3. Telegram over UnifiedPush via our ntfy

Client: **Mercurygram** (`it.belloworld.mercurygram`, F-Droid, GPL-2.0,
releases weekly). Forkgram's UnifiedPush is broken since 12.10
(Forkgram#507, #481) and copied Mercurygram's gateway design (#362);
Mercurygram is that design's upstream, decrypts pushes on the phone and
documents a self-hosted gateway. Its default gateway p2p.belloworld.it
answers ntfy endpoints with a fake 201 (blocked by ntfy.sh), so we run
our own: `https://tg-push.davhau.com/` (edi, admits only Telegram's
server ranges and only targets on ntfy.davhau.com/up*).

ntfy side: anonymous publish to `up*` topics only (what UnifiedPush
needs: Telegram's push carries no credentials), Dave reads them; every
other topic stays deny-all.

Taps (Dave, ~5 min; keep Forkgram until Mercurygram works):
1. ntfy app -> Settings -> **Default server** `https://ntfy.davhau.com`
   (the account `dave` is already there for voice-unlock; if not: Users ->
   add `https://ntfy.davhau.com`, user `dave`, his password). Settings ->
   UnifiedPush -> **Allow distributor** on.
2. F-Droid -> install **Mercurygram**, log in (Telegram code).
3. Mercurygram -> Settings -> Mercurygram -> Notifications ->
   UnifiedPush: pick **ntfy**; WebPush gateway
   `https://tg-push.davhau.com/` (with the trailing slash). Settings ->
   Notifications and Sounds: Background connection OFF, Keep-Alive
   service OFF. Android: Mercurygram battery **Unrestricted**.
4. Test: send yourself a Telegram message from another device with the
   phone locked. Then uninstall Forkgram.

Check on edi: `journalctl -u aesgcm-proxy -f` shows `aesgcm` forwards;
`journalctl -u nginx` 403s on tg-push mean a request outside the
allowed shape.
