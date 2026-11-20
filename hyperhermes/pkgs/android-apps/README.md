# Patches for the Hermes phone apps (Android)

Dave's phone runs two third-party Hermes clients, both installed with
Obtainium from their GitHub releases. Neither is built in this repo; these
patches are the fixes for the "reconnects after a one-second app switch,
then the message field is dead" bug, kept here until upstream has them.

| app | package | source | base |
|---|---|---|---|
| Hermes Relay | `com.axiomlabs.hermesrelay.sideload` | github.com/Codename-11/hermes-relay | tag `android-v1.19.0` |
| Hermes Mobile | `com.m57.hermescontrol` | github.com/Hy4ri/hermes-mobile | tag `v3.5.3` |

Shared cause, on the phone: Android destroys a backgrounded app's TCP
sockets seconds after it leaves the screen, so each brief switch costs a
`/api/auth/ws-ticket` + `/api/ws` upgrade + history reload, 3-6 s over
mobile data. The server side (hermes' dashboards behind nginx, module
`../../modules/dashboards/`) has no idle timeout involved: the sockets
there run with a 1 h proxy timeout and 20 s pings. What it did add: the
history reload (1-3 MB of JSON, two or three times per return) went out
uncompressed. The dashboards module now gzips the transcript and session
list.

- `hermes-relay-keep-composer-on-resume.patch`: the composer is gated on
  the gateway being Ready; the resume probe's "signed in, socket decides"
  verdict replaced Ready while the socket redialed. It now keeps Ready on
  the same route while the client is only redialing (a send waits for the
  dial; a failed dial still downgrades). Upstream: not yet reported.
- `hermes-mobile-keep-socket-on-app-switch.patch`: `onStop` closed an
  idle socket at once and the text field was disabled until it was back.
  The socket now outlives the background for 60 s, a dropped one is
  redialed at once on return (no backoff wait), and the text field stays
  editable while reconnecting (only Send waits). Upstream: not yet
  reported.

Build (debug): `git am` the patch on the base tag, then `./gradlew
:app:assembleDebug` (Hermes Mobile, in its own `nix develop`; package
`com.m57.hermescontrol.dev`, installs side by side) or
`:app:assembleSideloadDebug` (Hermes Relay: build-tools 36.0.0, platforms
36 + 37, JDK 17 toolchain; same package as the store build, so it cannot
sit next to it). An `adb install -r` over Dave's Obtainium installs needs
the release signing key, which only upstream has: the fixes reach those
installs through upstream releases.
