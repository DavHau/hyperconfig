/*
  The geninf-space: an agent's place for generational-infrastructure's
  work: its own clan (gi-infra: the repository on git.geninf.io, its
  machines and its vars), agave's clan (agave-infra), and every
  repository of the org on git.geninf.io (agave, agave-*, gi-website,
  tranquil-pds, ...) and gi's on git.clan.lol. Nothing of this clan's:
  ./default.nix has what every space leaves out.

  It replaced the gi-infra and agave spaces (2026-11-11; ./README.md,
  History): gi-infra's registry slot, ids and keys under the new name,
  agave's root key as a second credential, both homes merged.

  Identities (clan vars of the space's machine, no prompts; Dave adds each
  public value where it opens something, ./README.md has the steps):
    space-geninf-space-root-ssh        root on gi-infra's machines;
                                       credential `root-ssh`, the guest's
                                       default identity for every host but
                                       the forges, and its default age
                                       identity (AGE_KEYFILE).
    space-geninf-space-root-ssh-agave  root on agave-infra's machines (in
                                       agave-infra's clan.nix `adminKeys`
                                       as davhau-agave-space); credential
                                       `root-ssh-agave`, ssh's first
                                       identity for agave-infra's hosts
                                       (agaveHosts below). Was the agave
                                       space's root key; to be dropped once
                                       agave-infra lists root-ssh instead.
    space-geninf-space-git-geninf      git on git.geninf.io (davhau-gi-bot's
                                       key); credential `git-geninf`.
    space-geninf-space-git-clan-lol    git on git.clan.lol (davhau-clan-bot's
                                       key); credential `git-clan-lol`.
  API tokens (prompted clan vars, entered by Dave) of the bot accounts the
  ssh keys belong to, for PRs with `tea` (./forges.nix) and the org's
  repository list (space.orgCheckouts, ./guest.nix):
    space-geninf-space-token-geninf    davhau-gi-bot on git.geninf.io;
                                       credential `token-geninf`.
    space-geninf-space-token-clan-lol  davhau-clan-bot on git.clan.lol;
                                       credential `token-clan-lol`.
  One key per forge, not one for both: the two Gitea instances are run by
  different groups and each key is registered on one account there, so
  either can be revoked or rotated without touching the other, and a key
  showing up in one forge's logs says which.

  The clans' vars (clan's age store) decrypt with an ssh-ed25519 key: age
  takes it as recipient and its private key as identity, and agave-infra's
  clan.nix appends every plain ssh-ed25519 key of `adminKeys` to its age
  recipients. AGE_KEYFILE (read by clan before ~/.config/age/identities)
  and SOPS_AGE_SSH_PRIVATE_KEY_FILE point at root-ssh; for agave-infra's
  vars while it lists only the agave key:

    cd ~/agave-infra && AGE_KEYFILE=/run/geninf-space/secrets/root-ssh-agave clan vars ...

  No TPM identity is made, but the TPM stays bound in (`tpm`, as the
  gi-infra space had it): an `age-plugin-tpm` identity needs AGE_KEYFILE
  unset. The keys are clan vars of this clan, readable by whoever
  decrypts this clan's vars (infra-space, Dave), which Dave chose.

  Host keys pinned: the forges' published keys (./forge-host-keys.nix);
  gi-infra's machines by gi-infra's sshd CA (its `openssh-ca` var) for
  their `<machine>.personal.computer` names; agave-infra's machines by
  their `openssh` vars (agave-infra: vars/per-machine/<m>/openssh/
  ssh.id_ed25519.pub, never regenerated) for the addresses of its
  modules/hosts.nix, which its deploy.targetHost uses (agave-infra has
  no sshd CA). Other machines reached by IP: first contact asks, or the
  agent's ~/.ssh/known_hosts (persisted) has them.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  name = "geninf-space";
  gen = "space-${name}";
  cfg = config.hyper.spaces.${name};
  vars = config.clan.core.vars.generators;
  containerUnit = "container@${name}.service";
  secretsDir = "/run/${name}/secrets";
  machine = config.clan.core.settings.machine.name;

  sshKey = comment: {
    files.id_ed25519.restartUnits = [ containerUnit ];
    files."id_ed25519.pub".secret = false;
    runtimeInputs = [ pkgs.openssh ];
    script = ''
      ssh-keygen -q -t ed25519 -N "" -C ${lib.escapeShellArg comment} -f "$out"/id_ed25519
    '';
  };
  token = description: {
    prompts.token = {
      type = "hidden";
      persist = true;
      inherit description;
    };
    files.token.restartUnits = [ containerUnit ];
  };

  forges = import ./forge-host-keys.nix;
  # gi-infra's sshd CA (gi-infra: vars/shared/openssh-ca/id_ed25519.pub)
  # and the domain its host certificates name (clan.nix meta.domain).
  giCertAuthority = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEnYZY9mXckSBVf7TNA/xAtLb7cZs2rTuCz1hHO5gbwp";
  giDomain = "personal.computer";

  # agave-infra's machines: modules/hosts.nix addresses, host keys from
  # vars/per-machine/<m>/openssh/ssh.id_ed25519.pub/value.
  agaveHosts = {
    agave-app-01 = {
      addresses = [
        "2.31.31.53"
        "2a01:4f8:c016:ffa8::1"
      ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILVTtm4HbXpnm0RCFVZ1IKqwNam9O+e8IWKSB+JzP9mU";
    };
    agave-hosted-01 = {
      addresses = [
        "2.31.36.156"
        "2a01:4f8:c016:21f4::1"
      ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMzXTaQ2ESDw2Wp50besIsfxhZA2SCEfA2cfgK4FgMM";
    };
    agave-pds-01 = {
      addresses = [
        "77.42.127.137"
        "2a01:4f9:c015:2ce5::1"
      ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ5b2TUKXJeSURsdK8ZW9FQItDZEKYqfuh82Dvz39uOu";
    };
  };
  agaveHostPatterns = lib.concatStringsSep " " (
    lib.concatLists (lib.mapAttrsToList (m: h: [ m ] ++ h.addresses) agaveHosts)
  );
in
{
  config = {
    clan.core.vars.generators = lib.mkIf cfg.enable {
      "${gen}-root-ssh" = sshKey "${name}@${machine} (root on gi-infra)";
      "${gen}-root-ssh-agave" = sshKey "${name}@${machine} (root on agave-infra)";
      "${gen}-git-geninf" = sshKey "${name}@${machine} (git.geninf.io)";
      "${gen}-git-clan-lol" = sshKey "${name}@${machine} (git.clan.lol)";
      # API tokens of the forge bot accounts (PRs: open, comment, merge),
      # entered by Dave: `clan vars generate <machine> --generator <name>`.
      "${gen}-token-geninf" =
        token "git.geninf.io API token of davhau-gi-bot (write:repository, write:issue, read:user)";
      "${gen}-token-clan-lol" =
        token "git.clan.lol API token of davhau-clan-bot (write:repository, write:issue, read:user)";
    };

    # Its own definitions not under its `enable` (that would recurse);
    # inert while the space is off.
    hyper.spaces.${name} = {
      # for an age identity of gi-infra's vars sealed to this host (above)
      tpm = true;
      credentials = {
        root-ssh = vars."${gen}-root-ssh".files.id_ed25519.path;
        root-ssh-agave = vars."${gen}-root-ssh-agave".files.id_ed25519.path;
        git-geninf = vars."${gen}-git-geninf".files.id_ed25519.path;
        git-clan-lol = vars."${gen}-git-clan-lol".files.id_ed25519.path;
        token-geninf = vars."${gen}-token-geninf".files.token.path;
        token-clan-lol = vars."${gen}-token-clan-lol".files.token.path;
      };
      guestModules = [
        {
          programs.ssh.knownHosts =
            forges
            // {
              gi-infra-ca = {
                certAuthority = true;
                hostNames = [ "*.${giDomain}" ];
                publicKey = giCertAuthority;
              };
            }
            // lib.mapAttrs (m: h: {
              hostNames = [ m ] ++ h.addresses;
              inherit (h) publicKey;
            }) agaveHosts;
          # The clans' vars: root-ssh as age identity (above).
          environment.variables = {
            AGE_KEYFILE = "${secretsDir}/root-ssh";
            SOPS_AGE_SSH_PRIVATE_KEY_FILE = "${secretsDir}/root-ssh";
          };
          programs.ssh.extraConfig = ''
            Host git.geninf.io
              User gitea
              IdentityFile ${secretsDir}/git-geninf
              IdentitiesOnly yes

            Host git.clan.lol
              User gitea
              IdentityFile ${secretsDir}/git-clan-lol
              IdentitiesOnly yes

            # agave-infra's machines: its admin key first (IdentityFile
            # accumulates, root-ssh below is tried next)
            Host ${agaveHostPatterns}
              IdentityFile ${secretsDir}/root-ssh-agave

            # gi-infra's machines and the rest (`clan machines update`
            # goes to root@<address>)
            Host * !git.geninf.io !git.clan.lol
              IdentityFile ${secretsDir}/root-ssh
              IdentitiesOnly yes
          '';
          # gi-infra's flake fetches these over https; ../git.nix has the
          # same rewrite for Dave's own key.
          programs.git.config.url."ssh://gitea@git.geninf.io/generational-infrastructure/agave".insteadOf =
            "https://git.geninf.io/generational-infrastructure/agave";
          # PRs: `tea` (./forges.nix)
          space.forges = {
            "git.geninf.io" = {
              user = "davhau-gi-bot";
              credential = "token-geninf";
            };
            "git.clan.lol" = {
              user = "davhau-clan-bot";
              credential = "token-clan-lol";
            };
          };
          space.defaultForge = "git.geninf.io";
          # Every repository of the org the bot sees, new ones included
          # (./guest.nix).
          space.orgCheckouts."git.geninf.io" = {
            org = "generational-infrastructure";
            credential = "token-geninf";
          };
        }
      ];
    };
  };
}
