{config, pkgs, ...}: {
  services.vikunja = {
    enable = true;
    port = 8083;
    frontendScheme = "http";
    frontendHostname = "bam.d";
  };

  networking.firewall.interfaces.ygg.allowedTCPPorts = [ config.services.vikunja.port ];
}
