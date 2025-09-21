{
  # networking.nameservers = [
  #   "1.1.1.1"
  #   "1.0.0.1"
  # ];

  services.resolved = {
    enable = true;
    dnssec = "allow-downgrade";
    domains = [ "~." ];
    fallbackDns = [
      "1.1.1.1"
      "1.0.0.1"
    ];
    dnsovertls = "opportunistic";
  };
}
