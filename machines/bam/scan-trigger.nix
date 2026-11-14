# The LAN scan page for the Canon MF272dw (../../modules/nixos/scan-trigger):
# http://192.168.8.250:8088/ from the home LAN; scans land in
# /vault/misc/scans/<year>/ as Dave's 0600 files. bam because it is the
# always-on LAN host that holds the vault itself (no NFS hop), and
# 192.168.8.250 is its static LAN alias (../../modules/nixos/vault-nfs-server.nix).
{
  imports = [ ../../modules/nixos/scan-trigger ];

  hyper.scanTrigger = {
    enable = true;
    printerAddress = "192.168.18.20";
    listenAddress = "192.168.8.250";
    interface = "br0";
    hostNames = [ "bam" ];
    allowedNetworks = [ "192.168.8.0/24" ];
    owner = "dave";
    outputDir = "/vault/misc/scans";
    requireMount = "/vault/misc";
  };
}
