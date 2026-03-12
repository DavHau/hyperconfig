{pkgs, inputs, lib, ...}: {
  environment.systemPackages = [
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi
  ]
  ++ (lib.attrValues inputs.mics-skills.packages.${pkgs.stdenv.hostPlatform.system});

}
