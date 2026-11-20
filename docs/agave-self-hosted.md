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
   secrets; each revocable alone. Agave never force-pushes.
8. Upstream changes go as small PRs to generational-infrastructure/agave
   that can merge fast, behind a setting or behaviour-neutral. Dave
   reviews them himself before they merge.
9. (2026-11-20) No force-push protection on GitHub's `main`: Dave
   force-pushes it sometimes. Agave's push is fast-forward only, which
   is the one guard against Agave rewriting it.
10. (2026-11-20) Agave has root on every machine, through the tunnels
    only: its tenant key (`space-agave-host-tenant-ssh`) is authorized
    for root with `from="127.0.0.1,::1"` (H10).
11. (2026-11-20) Agave gets a write deploy key on GitHub for hyperconfig
    (`space-agave-host-github`); Dave adds its public value himself.
12. (2026-11-20) Public mirror of agave at https://git.geninf.io/agave/agave,
    so evaluators without a geninf key (joy, fresh checkouts) can fetch
    the `agave` input. It is a plain repo (not a pull mirror) holding
    only `main`; the input moves to it once it carries the pinned
    branch (Status log).

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
| A2 | Repo mode: `services.agave.repository` (url, branch, key): ~/fleet is a clone of an existing repo; the template sync never touches it | off by default | Words #702 | [#735](https://git.geninf.io/generational-infrastructure/agave/pulls/735), reviewed three rounds (approve with nits, applied), waits for Dave; merge after #702 |
| A3 | Repo mode: computers come from the repo's clan inventory (offline until their tunnel connects, no install/wipe/remove); their tunnel keys come from the repo's public vars | repo mode only | A2 | [#736](https://git.geninf.io/generational-infrastructure/agave/pulls/736) (contains A2's commit), reviewed three rounds (approve), waits for Dave; merge after #735 |
| A4 | Each computer reports the commit it runs (`system.configurationRevision`); Agave shows Behind | neutral (no revision = nothing shown) | Words [#682](https://git.geninf.io/generational-infrastructure/agave/pulls/682) | [#685](https://git.geninf.io/generational-infrastructure/agave/pulls/685), reviewed (approve after fix-up), waits for Dave |
| A5 | Repo mode: fetch + rebase before a turn, push to the branch after a confirmed change, retry on reject, never force | repo mode only | A3 | [#737](https://git.geninf.io/generational-infrastructure/agave/pulls/737), reviewed (push key only in root's mirror, approval bound to the commit shown, rewound-branch guard), in the integration branch, waits for Dave; merge after #736 |
| A6 | `nixosModules.fleet` without the recipe framework (`config.blocks` optional) | neutral | – | [#677](https://git.geninf.io/generational-infrastructure/agave/pulls/677), CI green, reviewed (approve), waits for Dave |
| W1 | Words: **behind** | Words only | – | [#682](https://git.geninf.io/generational-infrastructure/agave/pulls/682), reviewed, waits for Dave |
| W2 | Words: **the repository**, **repo mode**, **repository computer** | Words only | – | [#702](https://git.geninf.io/generational-infrastructure/agave/pulls/702), reviewed, waits for Dave |
| A7 | Deploy target aliases for repo machines whose `deploy.targetHost` is not `root@<name>` | repo mode only | A2 | later |
| A8 | The tenant's age key as one more recipient of the repo's secrets (C2), secrets store beside the fleet | repo mode only | A2 | later |
| A9 | Commits carry the person as author, Agave as committer (Q5) | neutral | – | later |

Integration branch: `davhau/self-hosted` in agave merges every open PR
branch above on top of `main` (rebuilt from scratch whenever a PR
branch changes; it is never a PR itself). hyperconfig's `agave` input pins it. It
goes away once the PRs merge upstream: then the pin moves back to
agave `main` at a rev Dave picks.

## hyperconfig steps

| Step | What | Status |
|---|---|---|
| H1 | This doc | done |
| H2 | flake input `agave` pinned to the integration branch | on main, vars generated, reviewed twice (approve with nits); waits for deploy |
| H3 | tranquil-pds on som: pds.davhau.com, handle domain davhau.com, PDS-hosted did:web on, invite-only, no relay crawl (`modules/nixos/atproto-pds`, `machines/som/atproto-pds.nix`; DNS records and certificate on som, since `*.davhau.com` points at edi) | on main (8583ae5c), vars generated; waits for deploy of som |
| H4 | Dave's account dave.davhau.com (did:web), created by `atproto-pds-accounts.service`; password from the prompt-free clan var `atproto-pds-dave-password` (random until Dave sets his own: `clan-secret-prompt som atproto-pds-dave-password password`, then a deploy applies it) | on main, var generated; waits for deploy of som |
| H5 | space `agave-host` (registry index 3, sshPort 2226, uids 1220/1221) running `services.agave`, in repo mode on hyperconfig's `main` (input at the integration branch with A5) | on main, vars generated, reviewed; waits for deploy and for Dave's deploy key on GitHub |
| H6 | SNI backend agave.davhau.com (443 and 80) -> 10.235.0.14 | on main, vars generated, reviewed twice (approve with nits); waits for deploy |
| H7 | Mullvad egress source `ve-agave-host` | on main, vars generated, reviewed twice (approve with nits); waits for deploy |
| H8 | clan vars: TeamClaude client key `space-agave-host-teamclaude`, `agave-geninf-ro` credential, hyperconfig push key `space-agave-host-github` (GitHub deploy key with write: Dave adds it; no branch protection on main, decision 9), tenant key `space-agave-host-tenant-ssh` (root's key on every machine, `from="127.0.0.1,::1"`: usable only through a tunnel) | on main, vars generated, reviewed twice (approve with nits); waits for deploy |
| H9 | `nixosModules.fleet` (tunnel only: no desktop, no Wi-Fi) on every machine incl. amy and vit, dialing agave.davhau.com in TLS | on main, vars generated, reviewed twice (approve with nits); waits for deploy |
| H10 | Agave's tenant ssh key authorized for root on every machine (public value in the repo, revocable by removing it) | on main, vars generated, reviewed twice (approve with nits); waits for deploy |
| H11 | Rented leaf machines (agave-vm-host): off until the last step | later |

## Milestones

- M1 Dave signs in at agave.davhau.com as dave.davhau.com (H2-H8, A2).
- M2 Agave shows every machine of hyperconfig (A3).
- M3 All machines online through their tunnels, Behind shown (A4, H9, H10).
- M4 Agave writes a change Dave confirmed to `main` (A5, push key).
- M5 Secrets (A8) and rented leaf machines (H11).

## Where it lives

- input `agave`: `flake.nix`, still the private repo over ssh; infra-space
  fetches it with `agave-geninf-ro` (`modules/nixos/infra-space/guest.nix`).
  Keyless evaluators need the public mirror (decision 12).
- the space: `modules/nixos/spaces/agave-host.nix` (server, SNI backend,
  Mullvad, TeamClaude client, DNS A records, keys), registry entry in
  `modules/nixos/spaces/registry.nix`.
- the tunnel and the tenant's root key: `modules/nixos/agave-tunnel.nix`
  (importer instance `agave-tunnel` in
  `modules/flake-parts/nixosConfigurations.nix`, key file through
  `modules/nixos/infra-space/fleet-access.nix`, usable only through the
  tunnels: `from="127.0.0.1,::1"`). The revision for A4's Behind is an
  opt-in there, `hyper.agaveTunnel.reportRevision`, off everywhere: it
  changes a machine's toplevel on every commit.
- DNS: `*.davhau.com` points at edi, so agave.davhau.com and
  *.agave.davhau.com get their own A record (som's public IPv4, sgp's),
  no AAAA (som's IPv6 443 is its own nginx).

## Status log

- 2026-11-19: plan reconstructed and committed (the scratch copy was lost).
- 2026-11-19: #677, #682, #685, #702 open for Dave's review (no merge scheduled, label needs-decision); A2/A3/A5 in review fix-ups; PDS (H3/H4) implemented and reviewed in its own change; the agave-host space (H2, H5-H10) in progress.
- 2026-11-20: PDS (H3/H4) and the host + tunnel (H2, H5-H10) on main with every var generated; #735 (A2) and #736 (A3) open; A5 in its last review; the repo-mode change (re-lock + repository block) waits for A5. Before repo mode: Dave protects hyperconfig's main on GitHub (no force-push, no deletion), then adds som's `space-agave-host-github` public key as a write deploy key.
- 2026-11-20: repo mode on main (input at `davhau/self-hosted` 42ae0d04, with A5 = #737). Dave decided: no force-push protection on main, Agave has root on every machine through the tunnels, Agave gets a write deploy key (Dave adds it), a public agave mirror. The mirror (agave/agave) is a plain repo with only `main` (38cb0876), not a pull mirror, so the input stays on the private repo: keyless evaluation needs `davhau/self-hosted` there (convert it to a pull mirror of generational-infrastructure/agave mirroring all branches, or push the branch to it), then the input moves to `git+https://git.geninf.io/agave/agave?ref=davhau/self-hosted`, same rev and narHash. agave-tunnel no longer restarts every 5 s while Agave doesn't list a machine (backoff to 5 min) and no longer fails deploys.
