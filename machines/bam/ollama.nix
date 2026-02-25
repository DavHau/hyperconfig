{
  services.ollama.enable = true;
  services.ollama.host = "[::]";
  networking.firewall.interfaces.ygg.allowedTCPPorts = [ 11434 ];
}
