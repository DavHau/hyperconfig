{
  networking.nameservers = [
    "1.1.1.1"
    "1.0.0.1"
  ];

  services.resolved = {
    enable = true;
    # dnssec = "allow-downgrade";
    dnssec = "true";
    domains = [ "~." ];
    fallbackDns = [
      "1.1.1.1"
      "1.0.0.1"
    ];
    # dnsovertls = "opportunistic";
    dnsovertls = "true";
  };

  programs.captive-browser.enable = true;
  programs.captive-browser.interface = "wlp1s0";
}
