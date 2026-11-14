# The home Canon i-SENSYS MF272dw (IoT Wi-Fi, fixed 192.168.18.20) as the
# default printer, driverless over IPP (AirPrint/IPP Everywhere, no Canon
# driver): A4, two-sided long edge by default (Duplex is the PPD option,
# sides the IPP one; GTK/Qt dialogs read either). Queue logic and why it
# doesn't use hardware.printers.ensurePrinters: ./lan-printer.nix.
# Device setup and scanning: docs/printer-mf272dw.md.
{
  imports = [ ./lan-printer.nix ];

  hyper.lanPrinter = {
    enable = true;
    name = "canon";
    address = "192.168.18.20";
    description = "Canon MF272dw";
    location = "Home";
    defaults = {
      PageSize = "A4";
      Duplex = "DuplexNoTumble";
      media = "iso_a4_210x297mm";
      sides = "two-sided-long-edge";
    };
  };
}
