{pkgs, config, ...}: {
  services.iodine.server = {
    enable = true;
    ip = "192.168.123.1/24";
    domain = "ns.bruch-bu.de";
    extraConfig = "-c";
    passwordFile = config.sops.secrets.iodine-password.path;
  };
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.ip_forward" = 1;
  };
  networking.firewall.allowedUDPPorts = [53];
}
