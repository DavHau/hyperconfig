/*
  The agave space: an agent's place to work on generational-
  infrastructure's agave project (agave and every agave-* repo on
  git.geninf.io). What else it needs is open (./README.md lists the
  questions); for now git on git.geninf.io and the common base. Nothing
  of this clan's: ./default.nix has what every space leaves out.

  Identities (clan vars of the space's machine, no prompts; their public
  values go where they open something, ./README.md has the steps):
    space-agave-root-ssh     root on agave-infra's machines (agave-infra's
                             clan.nix `adminKeys`); credential `root-ssh`,
                             the guest's default identity for every host
                             but git.geninf.io.
    space-agave-git-geninf   git on git.geninf.io (a Gitea account's key);
                             credential `git-geninf`.
  API token (a prompted clan var, entered by Dave) of the bot account the
  key belongs to, for PRs with `tea` (./forges.nix):
    space-agave-token-geninf davhau-agave-bot on git.geninf.io;
                             credential `token-geninf`.

  agave-infra's vars (clan's age store) decrypt with the same root-ssh
  key: age takes an ssh-ed25519 key as recipient and its private key as
  identity, and agave-infra's clan.nix appends every plain ssh-ed25519
  key of `adminKeys` to `adminAgeKeys`. So the one `adminKeys` entry
  makes the space root and a vars admin there (after a `clan vars fix`
  by an existing admin). AGE_KEYFILE points clan at the credential (clan
  reads it before ~/.config/age/identities); SOPS_AGE_SSH_PRIVATE_KEY_FILE
  does the same for sops. No TPM: the key is a clan var of this clan,
  readable by whoever decrypts this clan's vars (infra-space, Dave),
  which Dave chose over a TPM-sealed identity.

  Host keys pinned: git.geninf.io's published key; agave-infra's machines
  by their `openssh` vars (agave-infra: vars/per-machine/<m>/openssh/
  ssh.id_ed25519.pub, never regenerated, its README) for the addresses
  of its modules/hosts.nix, which its deploy.targetHost uses. agave-infra
  has no sshd CA (`certificate.enable = false`). A new or reinstalled
  machine is not pinned here until this list is updated: first contact
  asks, or the agent's ~/.ssh/known_hosts (persisted) has it.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  name = "agave";
  cfg = config.hyper.spaces.${name};
  vars = config.clan.core.vars.generators;
  containerUnit = "container@${name}.service";
  secretsDir = "/run/${name}/secrets";
  machine = config.clan.core.settings.machine.name;
  repo = r: "gitea@git.geninf.io:generational-infrastructure/${r}.git";

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
in
{
  config = {
    # root on agave-infra's machines (its clan.nix `adminKeys`)
    clan.core.vars.generators.space-agave-root-ssh = lib.mkIf cfg.enable {
      files.id_ed25519.restartUnits = [ containerUnit ];
      files."id_ed25519.pub".secret = false;
      runtimeInputs = [ pkgs.openssh ];
      script = ''
        ssh-keygen -q -t ed25519 -N "" -C "agave-space@${machine} (root on agave-infra)" -f "$out"/id_ed25519
      '';
    };

    clan.core.vars.generators.space-agave-git-geninf = lib.mkIf cfg.enable {
      files.id_ed25519.restartUnits = [ containerUnit ];
      files."id_ed25519.pub".secret = false;
      runtimeInputs = [ pkgs.openssh ];
      script = ''
        ssh-keygen -q -t ed25519 -N "" -C "agave-space@${machine} (git.geninf.io)" -f "$out"/id_ed25519
      '';
    };

    # API token of the forge bot account (PRs: open, comment, merge), entered
    # by Dave: `clan vars generate <machine> --generator space-agave-token-geninf`.
    clan.core.vars.generators.space-agave-token-geninf = lib.mkIf cfg.enable {
      prompts.token = {
        type = "hidden";
        persist = true;
        description = "git.geninf.io API token of davhau-agave-bot (write:repository, write:issue, read:user)";
      };
      files.token.restartUnits = [ containerUnit ];
    };

    # Its own definitions not under its `enable` (that would recurse);
    # inert while the space is off.
    hyper.spaces.${name} = {
      credentials = {
        root-ssh = vars.space-agave-root-ssh.files.id_ed25519.path;
        git-geninf = vars.space-agave-git-geninf.files.id_ed25519.path;
        token-geninf = vars.space-agave-token-geninf.files.token.path;
      };
      guestModules = [
        {
          programs.ssh.knownHosts = {
            inherit (import ./forge-host-keys.nix) git-geninf-io;
          }
          // lib.mapAttrs (m: h: {
            hostNames = [ m ] ++ h.addresses;
            inherit (h) publicKey;
          }) agaveHosts;
          # agave-infra's vars: the root-ssh key as age identity (above)
          environment.variables = {
            AGE_KEYFILE = "${secretsDir}/root-ssh";
            SOPS_AGE_SSH_PRIVATE_KEY_FILE = "${secretsDir}/root-ssh";
          };
          environment.systemPackages = [ pkgs.age ];
          programs.ssh.extraConfig = ''
            Host git.geninf.io
              User gitea
              IdentityFile ${secretsDir}/git-geninf
              IdentitiesOnly yes

            # agave-infra's machines (`clan machines update` goes to
            # root@<address>)
            Host * !git.geninf.io
              IdentityFile ${secretsDir}/root-ssh
              IdentitiesOnly yes
          '';
          # gi-infra's flake fetches these over https; ../git.nix has the
          # same rewrite for Dave's own key.
          programs.git.config.url."ssh://gitea@git.geninf.io/generational-infrastructure/agave".insteadOf =
            "https://git.geninf.io/generational-infrastructure/agave";
          # PRs: `tea` (./forges.nix)
          space.forges."git.geninf.io" = {
            user = "davhau-agave-bot";
            credential = "token-geninf";
          };
          space.checkouts = {
            agave = repo "agave";
            agave-marketplace = repo "agave-marketplace";
            agave-vm-host = repo "agave-vm-host";
            agave-infra = repo "agave-infra";
            agave-testbench = repo "agave-testbench";
          };
        }
      ];
    };
  };
}
