# The home printer as the default printer of a desktop (amy, vit, joy):
# a driverless (IPP Everywhere) queue `home` pointing at the queue the
# print server shares to the LAN (./home-printer-host.nix, served by the
# host in machines/<m>/printer.nix; address and queue name come from
# ./home-printer-server.nix, which that host reads too). A4 by default;
# duplex defaults are left to the device's PPD (unknown model). Queue
# logic and why it doesn't use hardware.printers.ensurePrinters:
# ./lan-printer.nix. Device and usage: docs/home-printer.md.
{ lib, ... }:
let
  srv = import ./home-printer-server.nix;
in
{
  imports = [ ./lan-printer.nix ];

  hyper.lanPrinter = {
    enable = true;
    name = srv.queue;
    uri = lib.mkDefault "ipp://${srv.address}:631/printers/${srv.queue}";
    description = "Home printer";
    location = "Home";
    # The previous network printer's queue.
    removeQueues = [ "canon" ];
    defaults = {
      PageSize = "A4";
      media = "iso_a4_210x297mm";
    };
  };
}
