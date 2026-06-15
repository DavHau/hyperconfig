# Extra llama-swap config for hyperconfig machines.
#
# Adds extra models to distro's base llama-swap config.
{ config, lib, ... }:
let
  cfg = config.services.llama-swap;
  llama-server = lib.getExe' cfg.llama-server-package "llama-server";

  # Fetch a gemma4 small-model GGUF from unsloth at a given quantization.
  fetchGemma4 =
    {
      size,
      quant,
      sha256,
    }:
    builtins.fetchurl {
      url = "https://huggingface.co/unsloth/gemma-4-${size}-it-GGUF/resolve/main/gemma-4-${size}-it-${quant}.gguf";
      inherit sha256;
    };

  gemma4-e2b-q4 = fetchGemma4 {
    size = "E2B";
    quant = "Q4_K_M";
    sha256 = "sha256-k3i8RxcQIp7xZXCbYuNL+2IjFCDdr21ynnJzBbW4Zy0=";
  };
  gemma4-e2b-q6 = fetchGemma4 {
    size = "E2B";
    quant = "Q6_K";
    sha256 = "sha256-s2gk8Tv5+rKRDLe0KCpNc7E3me5BJtTsJBMJzmnA54M=";
  };
  gemma4-e4b-q4 = fetchGemma4 {
    size = "E4B";
    quant = "Q4_K_M";
    sha256 = "sha256-UZuXk+1s4P9TDxt8luhI4I5J569NV7uX92IVljpUFG0=";
  };
  gemma4-e4b-q6 = fetchGemma4 {
    size = "E4B";
    quant = "Q6_K";
    sha256 = "sha256-Pb9j4ivoM9DmhPJrNtRUSPXyBvDnpsrGtKqeDPTJzOg=";
  };
  gemma4-e2b-q8 = fetchGemma4 {
    size = "E2B";
    quant = "Q8_0";
    sha256 = "sha256-CoSIsUnh9wBxLDXVvwo3lfncwlY7SUTV7y+4k3X5SD4=";
  };
  gemma4-e4b-q8 = fetchGemma4 {
    size = "E4B";
    quant = "Q8_0";
    sha256 = "sha256-oiMqZJUjw2v1MPHcNhTrjIAGRcQic5A4HIsF1Nbu4Fo=";
  };
  # UD-Q5_K_XL: unsloth-dynamic Q5, sweet spot for 16G Blackwell (8.6G weights,
  # ~7G left for KV cache); higher quality-per-VRAM than Q4_K_M.
  gemma4-12b-q5 = fetchGemma4 {
    size = "12b";
    quant = "UD-Q5_K_XL";
    sha256 = "sha256-AA0MwTH53ZMrTCPBimlJ2vmD33YrXYkJPfhVP6u+3ek=";
  };
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
    "gemma4:12b" = {
      cmd = "${llama-server} -m ${gemma4-12b-q5} --port \${PORT}";
    };
    "gemma4:e2b-q4_k_m" = {
      cmd = "${llama-server} -m ${gemma4-e2b-q4} --port \${PORT}";
    };
    "gemma4:e2b-q6_k" = {
      cmd = "${llama-server} -m ${gemma4-e2b-q6} --port \${PORT}";
    };
    "gemma4:e2b-q8_0" = {
      cmd = "${llama-server} -m ${gemma4-e2b-q8} --port \${PORT}";
    };
    "gemma4:e4b-q4_k_m" = {
      cmd = "${llama-server} -m ${gemma4-e4b-q4} --port \${PORT}";
    };
    "gemma4:e4b-q6_k" = {
      cmd = "${llama-server} -m ${gemma4-e4b-q6} --port \${PORT}";
    };
    "gemma4:e4b-q8_0" = {
      cmd = "${llama-server} -m ${gemma4-e4b-q8} --port \${PORT}";
    };
  };
}
