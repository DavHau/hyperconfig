# Self-hosted Agave on som (repo mode)

Dave runs his own Agave at https://agave.davhau.com, signs in as
`dave.davhau.com` (did:web:dave.davhau.com, on his own PDS at
https://pds.davhau.com), and Agave manages hyperconfig itself: it lists
every machine of this clan, shows which ones are behind `main`, and
writes changes to `main` after Dave confirms them in its chat. It never
deploys on its own.

Spec: agave `docs/specs/2026-10-26-editing-the-fleet-outside-agave.md`
(Decisions, merged as agave #461) and
`docs/specs/2026-10-21-self-hosting-and-atproto-login-design.md`.

## Decisions (Dave, final)

1. Identity `did:web:dave.davhau.com`, handle `dave.davhau.com`, account
   on his own PDS `pds.davhau.com` (tranquil-pds) on som.
2. Agave writes to hyperconfig straight to `main` after Dave confirms in
   Agave's chat; never deploys on its own. No auto-deploy on push; the
   nightly bump keeps merging and Agave shows machines as Behind.
3. Rented machines (agave-vm-host) only as leaf machines: no mesh, no
   admin keys, only their own secrets; off until the last step.
4. The tunnel runs on the laptops too (amy, vit).
5. Dave stays in control: nobody else decides what is installed;
   marketplace items only when he picks them, committed and reviewed
   before deploy; no backdoor or other auth for Agave's admins; all
   self-hosted. Agave is pinned to a version Dave updates.
6. Container on som (space `agave-host`), reached through som's SNI
   passthrough (`services.hyperhermes.slots.sniBackends`) at
   agave.davhau.com; outbound via Mullvad (`hyper.mullvadEgress.sources`)
   except Nix fetches (som's nix-daemon).
7. Agave has its own keys: git push key for hyperconfig, ssh key for the
   machines, read-only key for the agave repos (`agave-geninf-ro`), its
   own TeamClaude client key and, later, its own age key for the
   secrets; each revocable alone. Nobody force-pushes.
8. Upstream changes go as small PRs to generational-infrastructure/agave
   that can merge fast, behind a setting or behaviour-neutral. Dave
   reviews them himself before they merge.

## How it fits together

```
 browser ──443──> som public IPv4/IPv6 ──SNI agave.davhau.com──> agave-host (10.235.0.14:443)
 amy/vit/bam/... agave-tunnel (ssh in TLS, ALPN agave-tunnel) ──443──> same SNI route
 agave-host ── outbound ──> wg-mullvad (Mullvad egress source ve-agave-host)
 agave-host ── nix builds/fetches ──> som's nix-daemon (direct)
 agave-host ── git push main ──> github.com:DavHau/hyperconfig (its own deploy key)
 Dave's browser ──> pds.davhau.com (tranquil-pds on som) ; dave.davhau.com/.well-known/did.json (same PDS)
```

## Upstream PRs (generational-infrastructure/agave)

All opened by davhau-gi-bot, review requested from davhau, NOT merged by
us. Each stands alone on `main` unless "after" says otherwise.

| PR | What | Setting / neutrality | after | Status |
|---|---|---|---|---|
| A1 (#462) | `nixosModules.fleet`, `agave.tunnel.*` options | neutral | – | merged |
| A2 | Repo mode: `services.agave.repository` (url, branch, key): ~/fleet is a clone of an existing repo; the template sync never touches it | off by default | – | see table below |
| A3 | Repo mode: computers come from the repo's clan inventory (offline until their tunnel connects, no install/wipe/remove); their tunnel keys come from the repo's public vars | repo mode only | A2 | |
| A4 | Each computer reports the commit it runs (`system.configurationRevision`); Agave shows Behind | neutral (no revision = nothing shown) | – | |
| A5 | Repo mode: fetch + rebase before a turn, push to the branch after a confirmed change, retry on reject, never force | repo mode only | A2 | |
| A6 | `nixosModules.fleet` without the recipe framework (`config.blocks` optional) | neutral | – | |
| A7 | Deploy target aliases for repo machines whose `deploy.targetHost` is not `root@<name>` | repo mode only | A2 | later |
| A8 | The tenant's age key as one more recipient of the repo's secrets (C2), secrets store beside the fleet | repo mode only | A2 | later |
| A9 | Commits carry the person as author, Agave as committer (Q5) | neutral | – | later |

Integration branch: `davhau/self-hosted` in agave merges every open PR
branch above on top of `main`. hyperconfig's `agave` input pins it. It
goes away once the PRs merge upstream: then the pin moves back to
agave `main` at a rev Dave picks.

## hyperconfig steps

| Step | What | Status |
|---|---|---|
| H1 | This doc | done |
| H2 | flake input `agave` pinned to the integration branch | |
| H3 | tranquil-pds on som: pds.davhau.com, handle domain davhau.com, PDS-hosted did:web on, invite-only, no relay crawl | |
| H4 | Dave's account dave.davhau.com (did:web), password from a prompted clan var (`clan-secret-prompt`), gated until set | |
| H5 | space `agave-host` (registry index 3, sshPort 2226, uids 1220/1221) running `services.agave` in repo mode | |
| H6 | SNI backend agave.davhau.com (443 and 80) -> 10.235.0.14 | |
| H7 | Mullvad egress source `ve-agave-host` | |
| H8 | clan vars: TeamClaude client key `teamclaude-agave-host`, `agave-geninf-ro` credential, hyperconfig push key `agave-host-github` (GitHub deploy key with write: Dave adds it once) | |
| H9 | `nixosModules.fleet` (tunnel only: no desktop, no Wi-Fi) on every machine incl. amy and vit, dialing agave.davhau.com in TLS | |
| H10 | Agave's tenant ssh key authorized for root on every machine (public value in the repo, revocable by removing it) | |
| H11 | Rented leaf machines (agave-vm-host): off until the last step | later |

## Milestones

- M1 Dave signs in at agave.davhau.com as dave.davhau.com (H2-H8, A2).
- M2 Agave shows every machine of hyperconfig (A3).
- M3 All machines online through their tunnels, Behind shown (A4, H9, H10).
- M4 Agave writes a change Dave confirmed to `main` (A5, push key).
- M5 Secrets (A8) and rented leaf machines (H11).

## Status log

- 2026-11-19: plan reconstructed and committed (the scratch copy was lost).
