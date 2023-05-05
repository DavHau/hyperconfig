{pkgs, ...}: {
  services.iodine.server = {
    enable = true;
    ip = "192.168.99.1";
    domain = "iodine.hsngrmpf.club";
    # TODO: set %PASSWORD% and manage via agenix
    extraConfig = "-c -P %PASSWORD%";
  };
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.ip_forward" = 1;
  };
}
