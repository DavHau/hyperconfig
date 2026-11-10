# Named agent spaces

`hyper.spaces.<name>`: a NixOS container per job, built like infra-space
(`../infra-space`) but with none of its fleet rights. Two on amy:
`gi-infra` and `agave`. Design and isolation: `./default.nix` (host side
`./host.nix`, shared with infra-space; guest `./guest.nix` on
`./guest-base.nix`, also infra-space's base).

| space    | ssh                         | user     | veth             | TPM | own keys (clan vars of amy) |
|----------|-----------------------------|----------|------------------|-----|-----------------------------|
| gi-infra | `[amy's ygg address]:2224`  | gi-infra | 10.235.0.4/30, fd23:5ace:0:1::/64 | yes | root-ssh, git-geninf, git-clan-lol |
| agave    | `[amy's ygg address]:2225`  | agave    | 10.235.0.8/30, fd23:5ace:0:2::/64 | no  | git-geninf |

Homes persist on amy at `/var/lib/spaces/<name>/home`. Dave's admin keys
log in. On amy, the launchers "gi-infra space" / "agave space" and herdr
machines `gi-infra` / `agave` (`./client.nix`) appear once the host keys
are generated.

## Bringing them up (Dave)

1. On a machine with the clan secrets: `clan vars generate amy`. Until
   then every `clan machines update` stops at the new vars. Generates
   `space-{gi-infra,agave}-hostkey`, `space-gi-infra-root-ssh`,
   `space-gi-infra-git-geninf`, `space-gi-infra-git-clan-lol`,
   `space-agave-git-geninf` (no prompts). Commit the public values
   (`vars/per-machine/amy/space-*`): the desktops pin the host keys from
   them.
2. Deploy amy.
3. Register the public keys (`clan vars get amy <generator>/id_ed25519.pub`):
   - `space-gi-infra-root-ssh`: gi-infra repository, `clan.nix`
     `orgAdminKeys` (the sshd instance's authorizedKeys, root on every
     gi machine) and, for the clan-lol machines, `clan-lol/modules/admins.nix`;
     deploy gi-infra's machines.
   - `space-gi-infra-git-geninf`: an SSH key of the account the space acts
     as on git.geninf.io, with write access to the internal and public
     repositories (a dedicated bot user in the orgs' teams, or Dave's
     account; see open questions).
   - `space-gi-infra-git-clan-lol`: the same on git.clan.lol.
   - `space-agave-git-geninf`: git.geninf.io, write on the agave
     repositories.
4. gi-infra's vars: in the gi-infra space, `mkdir -p ~/.config/age &&
   age-plugin-tpm --generate -o ~/.config/age/identities`, then add
   `age-plugin-tpm -y ~/.config/age/identities` to gi-infra's recipients
   (`orgAdminAgeKeys`) and `clan vars fix` there. Optional: without it the
   space deploys only machines whose vars it does not need to decrypt.

## Adding a space

An entry in `./registry.nix` (next index, port, uid pair; ids in
`../vault-ids.nix`), a module like `./agave.nix` imported by
`./default.nix`, `hyper.spaces.<name>.enable` on its machine.
