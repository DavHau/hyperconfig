{pkgs, inputs, lib, ...}: {
  environment.systemPackages = [
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi
    # oh-my-pi fork of pi-mono with built-in Claude-Max billing bypass
    # (billing header injection, cloaking user_id, TLS fingerprint
    # matching, OAuth identity block with ephemeral cache). Binary is `omp`.
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.omp
  ]
  ++ (lib.attrValues inputs.mics-skills.packages.${pkgs.stdenv.hostPlatform.system});

}
