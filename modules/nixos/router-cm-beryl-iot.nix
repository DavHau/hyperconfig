# WPA2 passphrase of the home router's IoT Wi-Fi (cm-beryl, the offline
# printer's network; ../../home-networks/sites.nix `home.iot`). Read by
# `nix run .#site-routers-apply` via
#     clan vars get amy router-cm-beryl-iot/psk
# and fed to the router over ssh stdin, so it never lands on a machine's
# disk (deploy = false) or in a command line. Typed once on the printer's
# own panel: `clan vars get amy router-cm-beryl-iot/psk` in your terminal.
#
# Generated, no prompt: 24 characters from an unambiguous alphabet
# (no 0/O/1/l/I), easy to enter on a device keypad; 52^24, ~136 bits.
{ pkgs, ... }:
{
  clan.core.vars.generators.router-cm-beryl-iot = {
    share = true;
    files.psk.deploy = false;
    runtimeInputs = [ pkgs.coreutils ];
    # A bounded read, then cut: `tr < /dev/urandom | head` dies of SIGPIPE
    # under pipefail. 52 of 256 byte values pass the filter: 4 KiB gives ~830.
    script = ''
      head -c 4096 /dev/urandom \
        | LC_ALL=C tr -dc 'abcdefghijkmnpqrstuvwxyzACDEFGHJKLMNPQRTUVWXY2345679' > "$out/pool"
      head -c 24 "$out/pool" > "$out/psk"
      rm "$out/pool"
      [ "$(wc -c < "$out/psk")" -eq 24 ]
    '';
  };
}
