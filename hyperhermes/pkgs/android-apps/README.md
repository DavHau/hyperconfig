# The Hermes phone apps (Android): our builds

Dave's phone runs two third-party Hermes clients. We build both from their
release tags with our patches, sign them with our own key and serve them
for Obtainium. Upstream's releases (signed by upstream) no longer install
over ours, nor ours over theirs, without an uninstall.

| app | package | source | base |
|---|---|---|---|
| Hermes Relay | `com.axiomlabs.hermesrelay.sideload` | github.com/Codename-11/hermes-relay | tag `android-v1.19.0`, flavor `sideload` |
| Hermes Mobile | `com.m57.hermescontrol` | github.com/Hy4ri/hermes-mobile | tag `v3.5.3` |

## Where they come from

- `default.nix`: release builds in the Nix sandbox (gradle deps from the
  lock files `deps-<app>.json` through nixpkgs' mitm-cache; the Android
  SDK from androidenv, its own aapt2), UNSIGNED and zip-aligned; flake
  outputs `hyperhermes#hermes-mobile`, `#hermes-relay`.
- `../../modules/android-apps.nix` (on som, `machines/som/hermes-agents.nix`):
  `android-apps-sign.service` signs them with the shared clan vars
  generator `android-app-signing` (never in the store) and nginx serves
  them without sign-in at `https://hermes.davhau.com/apps/<app>-<version>.apk`,
  index `https://hermes.davhau.com/apps/`.
- Back up the key: `clan vars get som android-app-signing/keystore.p12`
  and `/password`. Without it the next build only installs after an
  uninstall, which drops the app's data.

## Obtainium

Add app -> URL `https://hermes.davhau.com/apps/`, override source type
**HTML**; in the additional options set "Filter APKs by regular
expression" to `hermes-mobile-.*\.apk` (one entry) or
`hermes-relay-.*\.apk` (the other). The version comes from the file name.
Replacing an upstream install needs an uninstall first (other signer);
sign in again afterwards.

## The patches

Shared cause, on the phone: Android destroys a backgrounded app's TCP
sockets seconds after it leaves the screen, so each brief switch costs a
`/api/auth/ws-ticket` + `/api/ws` upgrade + history reload, 3-6 s over
mobile data. The server side (`../../modules/dashboards/`) has no idle
timeout involved (1 h proxy timeouts, 20 s pings); it now gzips the
history reload (1-3 MB of JSON, two or three times per return).

- `hermes-relay-keep-composer-on-resume.patch`: the composer is gated on
  the gateway being Ready; the resume probe's "signed in, socket decides"
  verdict replaced Ready while the socket redialed. It now keeps Ready on
  the same route while the client is only redialing (a send waits for the
  dial; a failed dial still downgrades).
- `hermes-mobile-keep-socket-on-app-switch.patch`: `onStop` closed an
  idle socket at once and the text field was disabled until it was back.
  The socket now outlives the background for 60 s, a dropped one is
  redialed at once on return (no backoff wait), and the text field stays
  editable while reconnecting (only Send waits).
- `*-unsigned-release.patch`: the release build type signs with nothing
  (upstream wants its CI keystore, or falls back to the debug key); the
  module signs.

Upstream: not reported yet; ready-to-paste PR texts for both fixes are in
infra-space's `~/.local/share/reminders/hermes-app-prs/`.

## Updating

Bump `version`, `tag` and `hash` in `default.nix`, rebase the patches
(`git am` on the new tag, `git format-patch`), then refresh the locks.
The apps build from their own nixpkgs, the hyperhermes input
`nixpkgs-android-apps` (pinned by rev): the locks hold exactly what its
gradle fetches, so the nightly nixpkgs bump never touches them. To move
it, change the rev in `hyperhermes/flake.nix`, `nix flake update
hyperhermes` at the repo root, and re-record from `hyperhermes/`:
`nix build .#<app>.mitmCache.updateScript -o upd &&
NIXPKGS_ALLOW_UNFREE=1 ./upd` (`USE_BWRAP=0` where bwrap is missing; two
at once need different `mitmCachePort`s). A build with a stale lock fails
instead of downloading.
