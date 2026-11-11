# Named agent spaces

`hyper.spaces.<name>`: a NixOS container per job, built like infra-space
(`../infra-space`) but with none of its fleet rights. One on som:
`geninf-space`. Design and isolation: `./default.nix` (host side
`./host.nix`, shared with infra-space; guest `./guest.nix` on
`./guest-base.nix`, also infra-space's base).

| space        | ssh                        | user         | veth             | TPM | own keys (clan vars of som) |
|--------------|----------------------------|--------------|------------------|-----|-----------------------------|
| geninf-space | `[som's ygg address]:2224` | geninf-space | 10.235.0.4/30, fd23:5ace:0:1::/64 | yes | root-ssh, root-ssh-agave, git-geninf, git-clan-lol, token-geninf, token-clan-lol |

Homes persist on som at `/var/lib/spaces/<name>/home`. Dave's admin keys
log in. On amy (Dave's desktop), the launcher "geninf-space space" and
the herdr machine `geninf-space` (`./client.nix`) appear once the host
key is generated; entries of retired spaces leave Dave's herdr at the
next switch (`./herdr-space-machines.py`).

geninf-space clones every repository of the generational-infrastructure
org on git.geninf.io that davhau-gi-bot sees (listed from the API every
15 min, new ones included; `space.orgCheckouts`, `./guest.nix`).

## History

The gi-infra and agave spaces ran on amy until 2026-11-10 and moved to
som with their keys: each var copied with `clan vars cp amy som
<generator>/<file>` (the keys are registered at the forges and in the
other clans, so they were not regenerated; the comments still say
`@amy`), the homes copied over.

On 2026-11-11 they were merged into geninf-space: gi-infra's registry
slot (index 1, port 2224, uids 1205/1206) and its keys, renamed
`space-gi-infra-*` -> `space-geninf-space-*` by moving the store
directories (per-machine secrets are encrypted to the machine's key, not
to the generator's name; public values unchanged), agave's root key
kept as `space-geninf-space-root-ssh-agave` (agave-infra's `adminKeys`
lists it as davhau-agave-space). agave's slot (index 2, port 2225,
uids 1207/1208) is retired, never reused. davhau-agave-bot and its key
and token are gone; davhau-gi-bot covers every org repository. Both
homes were merged into geninf-space's (the second copy of a repository
as `<repo>.from-agave`, agave's dotfiles as `*.from-agave`, afk session
paths rewritten to /home/geninf-space).

Moving a space again works the same way: point ./registry.nix at the
new machine, enable it there, `clan vars cp` every `space-<name>-*`
var while the old machine still declares them, copy
`/var/lib/spaces/<name>` with the container stopped, then disable it
on the old machine.

## Keys: where each public value goes

`clan vars get som <generator>/id_ed25519.pub`:
- `space-geninf-space-root-ssh`: gi-infra repository, `clan.nix`
  `orgAdminKeys` (root on every gi machine) and, for the clan-lol
  machines, `clan-lol/modules/admins.nix`; also its age recipients.
- `space-geninf-space-root-ssh-agave`: agave-infra, `clan.nix`
  `adminKeys` (as `davhau-agave-space`, there already). agave-infra
  appends plain ssh-ed25519 admin keys to its age recipients, so it
  decrypts agave-infra's vars:
  `AGE_KEYFILE=/run/geninf-space/secrets/root-ssh-agave clan vars ...` in
  ~/agave-infra (AGE_KEYFILE defaults to root-ssh). To retire it, add
  root-ssh to agave-infra's `adminKeys` instead
  (`davhau-geninf-space = "<root-ssh's public key>";`), `clan vars fix`
  and deploy there, then drop the credential here.
- `space-geninf-space-git-geninf`: davhau-gi-bot on git.geninf.io (team
  bots-write, every repository of the org).
- `space-geninf-space-git-clan-lol`: davhau-clan-bot on git.clan.lol.

agave-infra's machines' host keys are pinned from its `openssh` vars
(`./geninf-space.nix`); update them there when a machine is added.

## Pull requests

`tea` in the space has a login per forge (`tea logins list`):
davhau-gi-bot on git.geninf.io and davhau-clan-bot on git.clan.lol, with
the tokens of the prompted vars `space-geninf-space-token-*` (`clan vars
generate som --generator <name>` to set or rotate one; the space
restarts). The config with the tokens is written to the guest's /run at
boot, never to the home (`./forges.nix`). The agents' how-to is the
`forge-prs` skill (`./forge-prs-skill/SKILL.md`). After a deploy, in the
space: `space-forge-check` (each token authenticates as its bot; the
repositories it can push to).

## Adding a space

An entry in `./registry.nix` (next free index, port, uid pair; never a
retired one; ids in `../vault-ids.nix`), a module like
`./geninf-space.nix` imported by `./default.nix`,
`hyper.spaces.<name>.enable` on its machine, then `clan vars generate
<machine>` (no prompts but the tokens).
