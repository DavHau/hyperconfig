{pkgs, ...}: {
  services.ollama.enable = true;
  services.ollama.package = pkgs.ollama-vulkan;
}
