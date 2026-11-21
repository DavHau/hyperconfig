# som's part of ./default.nix: the agents that may read Dave's location.
#
# Per reader (hyper.owntracks.readers) a generator location-reader-<name>
# on som: a random bearer `token` (secret) and its `sha256` (public, read
# by cm-pi's ./home-assistant.nix, which keeps only the hash). Where each
# token goes:
#   infra        infra-space's container credential `location-token`
#                (/run/infra-space/secrets/location-token, owner infra);
#                adding it restarts the container once. Every process
#                running as `infra` can read it, unattended jobs too
#                (nightly bump, cve-watch and others that read untrusted
#                feeds): accepted at infra-space's trust level.
#   dave-hermes  /run/secrets/per-machine/som/location-reader-dave-hermes/token,
#                owner dave-hermes 0400 (as its ha-rack-plug-token).
# Both get the skill ./skill (dave-location) with their token's path.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.hyper.owntracks;
  vars = config.clan.core.vars.generators;
  tokenOf = name: vars."location-reader-${name}".files.token.path;
  skillFor =
    tokenFile:
    inputs.hyperhermes.lib.mkAgentSkill pkgs {
      name = "dave-location";
      src = pkgs.writeTextDir "SKILL.md" (
        lib.replaceStrings [ "@TOKEN_FILE@" ] [ tokenFile ] (builtins.readFile ./skill/SKILL.md)
      );
    };
  infraToken = "/run/infra-space/secrets/location-token";
in
{
  imports = [ ./default.nix ];

  clan.core.vars.generators = lib.listToAttrs (
    map (
      name:
      lib.nameValuePair "location-reader-${name}" {
        files.token = lib.optionalAttrs (name == "dave-hermes") {
          owner = "dave-hermes";
          group = "users";
        };
        files.sha256.secret = false;
        runtimeInputs = [
          pkgs.openssl
          pkgs.coreutils
        ];
        script = ''
          openssl rand -hex 32 | tr -d '\n' > "$out"/token
          sha256sum "$out"/token | cut -d' ' -f1 | tr -d '\n' > "$out"/sha256
        '';
      }
    ) cfg.readers
  );

  hyper.infraSpace.credentials.location-token = tokenOf "infra";
  hyper.infraSpace.guestModules = [
    { infraSpace.hermes.extraSkills = [ (skillFor infraToken) ]; }
  ];

  services.hyperhermes.agents.dave-hermes.skillDirs = [
    "${skillFor (tokenOf "dave-hermes")}/share/skills"
  ];
}
