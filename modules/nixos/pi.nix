{pkgs, inputs, lib, ...}: let
  sys = pkgs.stdenv.hostPlatform.system;
  configFile = pkgs.writeText "config.yml" ''
    modelRoles:
      default: anthropic/claude-opus-4-6:medium
  '';
  omp-wrapped = inputs.wrappers.lib.wrapPackage {
    inherit pkgs;
    package = inputs.llm-agents.packages.${sys}.omp;
    preHook = ''
      config_dir="''${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
      mkdir -p "$config_dir/skills/caveman"
      ln -sf ${configFile} "$config_dir/config.yml"
      ln -sf ${inputs.caveman}/skills/caveman/SKILL.md "$config_dir/skills/caveman/SKILL.md"
    '';
  };
in {
  environment.systemPackages = [
    inputs.llm-agents.packages.${sys}.pi
    omp-wrapped
  ]
  ++ (lib.attrValues inputs.mics-skills.packages.${sys});
}
