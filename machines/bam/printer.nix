# The home printer/scanner is plugged into bam by USB, and bam serves it:
# CUPS queue `home` shared to the LAN at ipp://192.168.8.250:631/printers/home
# (the desktops' ../../modules/nixos/home-printer.nix points there) and the
# scan page http://192.168.8.250:8088/ (scans land in
# /vault/misc/scans/<year>/ as Dave's 0600 files). bam because the device
# sits next to it, it is the always-on LAN host and holds the vault itself
# (no NFS hop); 192.168.8.250 is its static LAN alias
# (../../modules/nixos/vault-nfs-server.nix). Address and queue name come
# from ../../modules/nixos/home-printer-server.nix, which the desktops read
# too. To serve it from another host, move this file (and its import)
# there and change the address in that file. Docs: docs/home-printer.md.
let
  srv = import ../../modules/nixos/home-printer-server.nix;
in
{
  imports = [ ../../modules/nixos/home-printer-host.nix ];

  hyper.homePrinterHost = {
    enable = true;
    lanAddress = srv.address;
    inherit (srv) queue;
    interface = "br0";
    lanNetworks = [ "192.168.8.0/24" ];
  };

  hyper.scanTrigger = {
    hostNames = [ "bam" ];
    owner = "dave";
    outputDir = "/vault/misc/scans";
    requireMount = "/vault/misc";
  };
}
