/*
  The agave space: an agent's place to work on generational-
  infrastructure's agave project (agave and every agave-* repo on
  git.geninf.io). What else it needs is open (./README.md lists the
  questions); for now git on git.geninf.io and the common base. Nothing
  of this clan's: ./default.nix has what every space leaves out.

  Identity (a clan var of the space's machine, no prompt):
    space-agave-git-geninf   git on git.geninf.io (a Gitea account's key);
                             credential `git-geninf`.
  API token (a prompted clan var, entered by Dave) of the bot account the
  key belongs to, for PRs with `tea` (./forges.nix):
    space-agave-token-geninf davhau-agave-bot on git.geninf.io;
                             credential `token-geninf`.
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
in
{
  config = {
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
        git-geninf = vars.space-agave-git-geninf.files.id_ed25519.path;
        token-geninf = vars.space-agave-token-geninf.files.token.path;
      };
      guestModules = [
        {
          programs.ssh.knownHosts = { inherit (import ./forge-host-keys.nix) git-geninf-io; };
          programs.ssh.extraConfig = ''
            Host git.geninf.io
              User gitea
              IdentityFile ${secretsDir}/git-geninf
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
