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
    "qwen3.5:0.8b" = {
      cmd = "${llama-server} -hf unsloth/Qwen3.5-0.8B-GGUF --port \${PORT}";
    };
    "qwen3.5:27b" = {
      cmd = "${llama-server} -hf unsloth/Qwen3.5-27B-GGUF --port \${PORT}";
    };
    "qwen3.5:35b" = {
      cmd = "${llama-server} -hf unsloth/Qwen3.5-35B-A3B-GGUF:Q4_K_M --port \${PORT}";
    };
    "qwen3.5:122b" = {
      cmd = "${llama-server} -hf unsloth/Qwen3.5-122B-A10B-GGUF:UD-Q3_K_XL --port \${PORT}";
    };
    "gemma4:31b" = {
      cmd = "${llama-server} -hf unsloth/gemma-4-31B-it-GGUF:Q4_K_M --port \${PORT}";
    };
    "gemma4:26b" = {
      cmd = "${llama-server} -hf unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q4_K_M --port \${PORT}";
    };
    "gemma4:e4b" = {
      cmd = "${llama-server} -hf unsloth/gemma-4-E4B-it-GGUF:Q8_0 --port \${PORT}";
    };
  };
}