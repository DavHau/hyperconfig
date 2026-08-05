# Extra llama-swap config for hyperconfig machines.
#
# Adds extra models to distro's base llama-swap config.
{ config, lib, ... }:
let
  cfg = config.services.llama-swap;
  llama-server = lib.getExe' cfg.llama-server-package "llama-server";
in
{
  services.llama-swap.settings.models = {
    "qwen3.5:35b" = {
      cmd = "${llama-server} -hf unsloth/Qwen3.5-35B-A3B-GGUF:Q4_K_M --port \${PORT}";
    };
  };
}
