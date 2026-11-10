/*
  The agave space: an agent's place to work on generational-
  infrastructure's agave project (agave, agave-marketplace, agave-vm-host
  on git.geninf.io). What else it needs is open (./README.md lists the
  questions); for now git on git.geninf.io and the common base. Nothing
  of this clan's: ./default.nix has what every space leaves out.

  Identity (a clan var of the space's machine, no prompt):
    space-agave-git-geninf   git on git.geninf.io (a Gitea account's key);
                             credential `git-geninf`.
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

    # Its own definitions not under its `enable` (that would recurse);
    # inert while the space is off.
    hyper.spaces.${name} = {
      credentials.git-geninf = vars.space-agave-git-geninf.files.id_ed25519.path;
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
          space.checkouts = {
            agave = repo "agave";
            agave-marketplace = repo "agave-marketplace";
            agave-vm-host = repo "agave-vm-host";
          };
        }
      ];
    };
  };
}
