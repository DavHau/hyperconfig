/*
  The gi-infra space: an agent's place to run generational-infrastructure's
  own clan (the gi-infra repository on git.geninf.io, its machines and its
  vars), and to work on gi's repositories on git.geninf.io and
  git.clan.lol. Nothing of this clan's: ./default.nix has what every space
  leaves out.

  Identities (clan vars of the space's machine, no prompts; Dave adds each
  public value where it opens something, ./README.md has the steps):
    space-gi-infra-root-ssh      root on gi-infra's machines; credential
                                 `root-ssh`, the guest's default identity
                                 for every host but the forges.
    space-gi-infra-git-geninf    git on git.geninf.io (a Gitea account's
                                 key); credential `git-geninf`.
    space-gi-infra-git-clan-lol  git on git.clan.lol (likewise);
                                 credential `git-clan-lol`.
  One key per forge, not one for both: the two Gitea instances are run by
  different groups and each key is registered on one account there, so
  either can be revoked or rotated without touching the other, and a key
  showing up in one forge's logs says which.

  The age identity for gi-infra's vars is not a clan var: it is made in
  the guest, sealed to this host's TPM (tpm below), and its recipient goes
  into gi-infra's own clan.nix by hand. A clan var would be readable by
  whoever decrypts this clan's vars (infra-space, this host's root), and
  could leave the machine; the TPM-sealed key cannot.

  Host keys pinned: the forges' published ed25519 keys (git.clan.lol's rsa
  one too), as Dave's known_hosts on amy has them; gi-infra's machines by
  gi-infra's sshd CA (its `openssh-ca` var) for their
  `<machine>.personal.computer` names. Machines reached by IP (gi-infra's
  deploy.targetHost) have no pinned key here: first contact asks, or the
  agent's ~/.ssh/known_hosts (persisted) has them.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  name = "gi-infra";
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

  forges = import ./forge-host-keys.nix;
  # gi-infra's sshd CA (gi-infra: vars/shared/openssh-ca/id_ed25519.pub)
  # and the domain its host certificates name (clan.nix meta.domain).
  giCertAuthority = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEnYZY9mXckSBVf7TNA/xAtLb7cZs2rTuCz1hHO5gbwp";
  giDomain = "personal.computer";
in
{
  config = {
    clan.core.vars.generators = lib.mkIf cfg.enable {
      space-gi-infra-root-ssh = sshKey "gi-infra-space@${machine} (root on gi-infra)";
      space-gi-infra-git-geninf = sshKey "gi-infra-space@${machine} (git.geninf.io)";
      space-gi-infra-git-clan-lol = sshKey "gi-infra-space@${machine} (git.clan.lol)";
    };

    # Its own definitions not under its `enable` (that would recurse);
    # inert while the space is off.
    hyper.spaces.${name} = {
      # for the age identity of gi-infra's vars (above)
      tpm = true;
      credentials = {
        root-ssh = vars.space-gi-infra-root-ssh.files.id_ed25519.path;
        git-geninf = vars.space-gi-infra-git-geninf.files.id_ed25519.path;
        git-clan-lol = vars.space-gi-infra-git-clan-lol.files.id_ed25519.path;
      };
      guestModules = [
        {
          programs.ssh.knownHosts = forges // {
            gi-infra-ca = {
              certAuthority = true;
              hostNames = [ "*.${giDomain}" ];
              publicKey = giCertAuthority;
            };
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

            # gi-infra's machines (`clan machines update` goes to
            # root@<address>)
            Host * !git.geninf.io !git.clan.lol
              IdentityFile ${secretsDir}/root-ssh
              IdentitiesOnly yes
          '';
          space.checkouts.gi-infra = "gitea@git.geninf.io:generational-infrastructure/gi-infra.git";
        }
      ];
    };
  };
}
