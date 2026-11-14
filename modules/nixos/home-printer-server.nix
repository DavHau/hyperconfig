# Where the home printer is served (plain data, not a module): the print
# server's LAN address and its shared CUPS queue. One place for both
# sides: machines/bam/printer.nix (the server, hyper.homePrinterHost) and
# ./home-printer.nix (the desktops' queue URI). 192.168.8.250 is bam's
# static LAN alias (./vault-nfs-server.nix). Moving the printer to another
# host: change `address` here and move machines/bam/printer.nix.
{
  address = "192.168.8.250";
  queue = "home";
}
