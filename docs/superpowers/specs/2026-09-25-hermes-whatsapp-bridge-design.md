# Declarative WhatsApp bridge for native hermes agents

Date: 2026-09-25. Status: approved, implementing.
Scope: `modules/nixos/hermes-common.nix`, `pkgs/hermes-whatsapp-bridge`,
`machines/som/hermes-agents.nix`, spaces `modules/nixos/hermes/{options,native,guest}.nix`.

## Goal

An agent flagged `hyper.hermes.users.<name>.whatsapp.enable` gets everything
the WhatsApp (Baileys) bridge needs to run, declaratively. Pairing (QR scan)
stays in the hermes dashboard (Messaging -> WhatsApp), which writes
`WHATSAPP_*` to `.env`, enables the platform and restarts the gateway. The
gateway owns the bridge process (upstream lifecycle, no extra unit).

## Upstream facts (hermes 0.21.3)

- Dashboard pairing and the gateway both locate the bridge through
  `resolve_whatsapp_bridge_dir()`: a read-only install tree falls back to
  `$HERMES_HOME/scripts/whatsapp-bridge` when that exists, else copies the
  bridge there and runs `npm install` at runtime.
- The gateway re-runs `npm install` unless
  `node_modules/.hermes-pkg-hash` holds `sha256(package.json)[:16]`.
- The bridge writes only to its session dir and `$HERMES_HOME` caches.
- The bridge port is config-only: `gateway.platforms.whatsapp.extra.bridge_port`
  (default 3000) on 127.0.0.1, an unauthenticated HTTP API.

## Design

1. spaces: `services.hermes-microvm.users.<u>.settings` (YAML), recursively
   merged over the host `settings` into that user's config (native: the
   managed config.yaml, so the keys are locked; VM: the guest's settings).
2. `hermes-whatsapp-bridge`: `buildNpmPackage` of `scripts/whatsapp-bridge`
   from the pinned hermes source (`inputs.spaces.inputs.hermes-agent`) with
   the upstream lockfile; no build step; writes the dep stamp. Same pin as
   the running hermes, so versions cannot drift.
3. `hyper.hermes.users.<name>.whatsapp.enable` (native only, asserted):
   - tmpfiles `L+ <HERMES_HOME>/scripts/whatsapp-bridge -> <package>`, so
     dashboard pairing and gateway use the Nix bridge and never npm install;
   - per-user `gateway.platforms.whatsapp.extra.bridge_port = 30000 + uid`
     (dashboard 20000+uid, simplex 10000+uid; below the 32768 ephemeral
     range);
   - owner-only rules for that port appended to `hermes-firewall`: the
     owner and root pass, every other uid (other agents) gets a reset;
   - no `WHATSAPP_ENABLED/MODE/ALLOWED_USERS`: the dashboard writes them
     after a successful pairing (enabling unpaired only logs fatal errors).
4. som: `adam.hermes.whatsapp.enable = true`. Adam's manual attempt (mirrored
   bridge with runtime npm install, `WHATSAPP_*` in `.env`,
   `platforms.whatsapp` in config.yaml, empty session) is removed once.

## Verification

Eval som; after deploy: the bridge link resolves into the store; dashboard
`POST /api/messaging/whatsapp/onboarding/start` as the agent reaches
`waiting` with a QR payload (then cancel); the bridge port rejects other uids.
The actual scan is the user's.

## Risks

- The dashboard's post-pairing gateway restart relies on spaces'
  gateway-restart patch; fallback `systemctl restart hermes-agent-<name>`.
- Baileys is unofficial; self-chat links a personal account (ban risk per
  upstream docs). A dedicated bot number is safer.
