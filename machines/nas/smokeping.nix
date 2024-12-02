{
  networking.domain = "davhau.com"; # needed for smokeping
  networking.firewall.allowedTCPPorts = [80];
  services.nginx.virtualHosts.smokeping.forceSSL = true;
  services.nginx.virtualHosts.smokeping.enableACME = true;
  services.smokeping.enable = true;
  services.smokeping.webService = true;
  services.smokeping.host = "smokeping.bruch-bu.de";
  services.smokeping.targetConfig = ''
    probe = FPing
    menu = Top
    title = Network Latency Grapher
    remark = Welcome to the SmokePing website of DavHau.

    + Cloudflare
    menu = Cloudflare DNS

    ++ v4
    menu = Cloudflare DNS v4
    host = 1.1.1.1

    ++ v6
    menu = Cloudflare DNS v6
    host = 2606:4700:4700::1111

    + Google
    menu = Google DNS

    ++ v4
    menu = Google DNS v4
    host = 8.8.8.8

    ++ v6
    menu = Google DNS v6
    host = 2001:4860:4860::8888
  '';
}
