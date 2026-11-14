# lan-printer: one driverless (IPP Everywhere / AirPrint) CUPS queue for a
# network printer, created by our own oneshot instead of
# hardware.printers.ensurePrinters.
#
# Why not ensurePrinters: it runs `lpadmin -m everywhere` in cups.service's
# postStart under `set -e`, and `-m everywhere` must query the printer
# (Get-Printer-Attributes) to build the PPD. With the printer off, cups
# fails to start and with it the whole deploy. Here the queue is made by
# lan-printer-<name>.service, started only by lan-printer-<name>.timer
# (20 s after boot or a changed definition, then every 15 min): if the
# printer is unreachable it logs and exits 0, and the next run retries. Once it exists, later runs only re-apply
# URI and defaults (no printer query needed). Instance: ./printer-canon-mf272dw.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.lanPrinter;
  inherit (lib) mkOption types;
  q = lib.escapeShellArg;
  defaults = lib.concatMapStringsSep " " (o: "-o ${q o}") (
    lib.mapAttrsToList (k: v: "${k}=${v}") cfg.defaults
  );
in
{
  options.hyper.lanPrinter = {
    enable = lib.mkEnableOption "a driverless CUPS queue for a LAN printer";
    name = mkOption {
      type = types.strMatching "[A-Za-z0-9_-]+";
      example = "canon";
      description = "CUPS queue name.";
    };
    address = mkOption {
      type = types.str;
      example = "192.168.18.20";
    };
    uri = mkOption {
      type = types.str;
      default = "ipp://${cfg.address}/ipp/print";
      defaultText = lib.literalExpression ''"ipp://''${address}/ipp/print"'';
    };
    description = mkOption {
      type = types.str;
      default = cfg.name;
    };
    location = mkOption {
      type = types.str;
      default = "";
    };
    defaults = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        PageSize = "A4";
        Duplex = "DuplexNoTumble";
      };
      description = "Queue defaults (`lpadmin -o`): options of the generated PPD and IPP *-default attributes.";
    };
    makeDefault = mkOption {
      type = types.bool;
      default = true;
      description = "Make it the system default printer.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.printing.enable = true;

    # Started only by its timer, never by the switch itself: a deploy
    # never waits on (or fails over) the printer.
    systemd.services."lan-printer-${cfg.name}" = {
      description = "CUPS queue ${cfg.name} (${cfg.uri})";
      after = [
        "cups.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      requires = [ "cups.service" ];
      path = [
        config.services.printing.package
        pkgs.coreutils
      ];
      serviceConfig.Type = "oneshot";
      script = ''
        if ! lpstat -p ${q cfg.name} >/dev/null 2>&1; then
          # -m everywhere queries the printer for its attributes; that is
          # the step that fails while it is off.
          if ! timeout 90 lpadmin -p ${q cfg.name} -E -v ${q cfg.uri} -m everywhere; then
            echo "printer ${cfg.uri} not reachable; queue ${cfg.name} not created yet, retrying in 15 min"
            exit 0
          fi
          echo "created queue ${cfg.name}"
        fi
        # Re-applied on every run (no printer query): URI, texts, defaults.
        lpadmin -p ${q cfg.name} -E -v ${q cfg.uri} -D ${q cfg.description} -L ${q cfg.location} ${defaults}
        ${lib.optionalString cfg.makeDefault "lpadmin -d ${q cfg.name}"}
        cupsenable ${q cfg.name}
        cupsaccept ${q cfg.name}
      '';
    };

    systemd.timers."lan-printer-${cfg.name}" = {
      wantedBy = [ "timers.target" ];
      # A changed definition restarts the timer, which fires OnActiveSec
      # later: the switch applies it without waiting for it.
      restartTriggers = [ (builtins.toJSON cfg) ];
      timerConfig = {
        OnActiveSec = "20s";
        OnUnitInactiveSec = "15min";
      };
    };
  };
}
