# The home-networks skill (./home-networks-skill) for the som agents that
# may reach Roman's home LANs over zt-eu (../../home-networks): roman and
# Dave's dave-hermes.
{
  inputs,
  lib,
  pkgs,
  ...
}:
let
  skill = inputs.hyperhermes.lib.mkAgentSkill pkgs {
    name = "home-networks";
    src = lib.fileset.toSource {
      root = ./home-networks-skill;
      fileset = ./home-networks-skill/SKILL.md;
    };
  };
in
{
  services.hyperhermes.agents = lib.genAttrs [ "roman" "dave-hermes" ] (_: {
    skillDirs = [ "${skill}/share/skills" ];
  });
}
