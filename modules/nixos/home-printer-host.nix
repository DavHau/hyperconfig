# home-printer-host: serves the home printer/scanner that is plugged into
# this host by USB (model-agnostic: any IPP-over-USB device, i.e. most
# AirPrint/Mopria-certified printers and MFPs since ~2016, USB interface
# class 7/1/4). The serving host is chosen in one place: the machine that
# imports this through machines/<m>/printer.nix (bam); the desktops reach
# it at the address in ./home-printer-server.nix (shared with that
# machine). Device check, fallback and usage: docs/home-printer.md.
#
# Driver: ipp-usb (nixpkgs ipp-usb, our own unit instead of
# services.ipp-usb, which force-enables Avahi publishing, cups-browsed and
# SANE). udev starts ipp-usb.service when a 7/1/4 device appears; it runs
# in `udev` mode (exits when the last device is gone), so with no device
# plugged in nothing runs and nothing fails. It exposes the device's IPP
# (print), eSCL (scan) and its web admin page on ONE loopback port,
# pinned to cfg.usbPort (range usbPort..usbPort+1 for ipp-usb, which needs
# min < max; the first device gets usbPort and keeps it, persisted in
# /var/lib/ipp-usb/dev/), no DNS-SD, no IPv6, never on the LAN.
#
# Printing: CUPS here holds the queue cfg.queue -> ipp://localhost:<usbPort>/ipp/print
# (driverless, created by ./lan-printer.nix's timer, non-fatal while no
# device is plugged in; ipp-usb's start re-arms that timer so the queue
# appears ~20 s after plugging in). It is shared to the LAN only: cupsd
# listens on localhost:631 and cfg.lanAddress:631 (socket with FreeBind),
# the firewall opens 631 only for cfg.lanNetworks on cfg.interface, and
# cupsd allows LAN peers only on /printers/<queue> (everything else, the
# web UI and /admin stay localhost). No cups-browsed, no Browsing/announce:
# desktops are configured with the URI.
#
# The LAN is unauthenticated: IPP's requesting-user-name is whatever the
# client claims, so any LAN host can pose as dave (or root). Hence the op
# policy `lan` (cupsd's DefaultPolicy and the queue's printer-op-policy):
# from the LAN only printing and status (Print-Job, Create-Job,
# Send-Document, Validate-Job, Get-Printer-Attributes, Get-Jobs,
# Get-Job-Attributes); every other op is 403 before any authentication,
# so nothing asks for a password over the LAN, and Basic auth is off
# altogether (DefaultAuthType None: cupsd would otherwise run PAM on any
# request with an Authorization header, a brute-force oracle for a wheel
# user's password); no job can be cancelled, held or fetched
# (CUPS-Get-Document) by a spoofed owner. Device/PPD listing and
# subscriptions are localhost only too, and the rss/mailto notifiers are
# removed (a notify-recipient-uri rss://<host>/ makes cupsd connect out:
# SSRF; a Print-Job may carry one, so the policy alone doesn't stop it).
# Job files are deleted when a job ends (PreserveJobFiles No), the
# job list is kept 15 min, and job names / originating user and host are
# shown to nobody (JobPrivateAccess @ACL with no ACL set). Cancel on a
# desktop does not reach bam (Cancel-Job is localhost only): `cancel` on
# bam if a job must go.
#
# Scanning: ./scan-trigger pulls from http://localhost:<usbPort>/eSCL
# (ipp-usb); its LAN page and the rest stay as they are.
#
# Exposure on this host: loopback is reachable by every local user, so any
# local process can print and scan through ipp-usb. Its web admin page
# (the device's settings) is root-only: ipp-usb allows `config` to root,
# and under PrivateUsers=true every other uid shows up as nobody anyway.
# Nothing protects the device's settings beyond its PIN. Same trust as a
# LAN client of the scan page; acceptable on bam. CUPS admin operations
# work from localhost only (root through the local socket).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.homePrinterHost;
  inherit (lib) mkOption types;
  q = cfg.queue;
  iptIf = lib.optionalString (cfg.interface != null) "-i ${cfg.interface}";
  nftIf = lib.optionalString (cfg.interface != null) "iifname \"${cfg.interface}\"";
  # Op policy `lan` (see the header); the op groups as in nixpkgs'
  # <Policy default>.
  lanOps = [
    "Print-Job"
    "Create-Job"
    "Send-Document"
    "Validate-Job"
    "Get-Printer-Attributes"
    "Get-Jobs"
    "Get-Job-Attributes"
  ];
  ownerOps = [
    "Cancel-Job"
    "CUPS-Authenticate-Job"
    "Send-URI"
    "Hold-Job"
    "Release-Job"
    "Restart-Job"
    "Purge-Jobs"
    "Set-Job-Attributes"
    "Reprocess-Job"
    "Cancel-Current-Job"
    "Suspend-Current-Job"
    "Resume-Job"
    "CUPS-Move-Job"
    "Cancel-My-Jobs"
  ];
  adminOps = [
    "Pause-Printer"
    "Resume-Printer"
    "Set-Printer-Attributes"
    "Enable-Printer"
    "Disable-Printer"
    "Pause-Printer-After-Current-Job"
    "Hold-New-Jobs"
    "Release-Held-New-Jobs"
    "Deactivate-Printer"
    "Activate-Printer"
    "Restart-Printer"
    "Shutdown-Printer"
    "Startup-Printer"
    "Promote-Job"
    "Schedule-Job-After"
    "CUPS-Add-Printer"
    "CUPS-Delete-Printer"
    "CUPS-Add-Class"
    "CUPS-Delete-Class"
    "CUPS-Accept-Jobs"
    "CUPS-Reject-Jobs"
    "CUPS-Set-Default"
    "Cancel-Jobs"
  ];
  # Ops cupsd fills in from a template op when a policy doesn't name them
  # (conf.c: CUPS-Get-Document and Close-Job copy Send-Document's limit,
  # i.e. LAN-allowed here), so <Limit All> alone would not catch them.
  localOnlyOps = [
    "CUPS-Get-Document"
    "Close-Job"
  ];
  ops = lib.concatStringsSep " ";
in
{
  imports = [
    ./lan-printer.nix
    ./scan-trigger
  ];

  options.hyper.homePrinterHost = {
    enable = lib.mkEnableOption "serving a USB printer/scanner (ipp-usb) to the LAN";
    lanAddress = mkOption {
      type = types.str;
      example = "192.168.8.250";
      description = "LAN address cupsd listens on (and the scan page, see scanTrigger.listenAddress).";
    };
    lanNetworks = mkOption {
      type = types.listOf types.str;
      default = [ "192.168.8.0/24" ];
      description = "IPv4 client networks allowed to print (firewall and cupsd).";
    };
    interface = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "br0";
      description = "Open port 631 only on this interface (null: any).";
    };
    queue = mkOption {
      type = types.strMatching "[A-Za-z0-9_-]+";
      default = "home";
      description = "CUPS queue name, here and on the desktops.";
    };
    usbPort = mkOption {
      type = types.port;
      default = 60000;
      description = "Loopback port ipp-usb serves the device on (IPP, eSCL, web page).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (n: !(lib.hasInfix ":" n)) cfg.lanNetworks;
        message = "hyper.homePrinterHost.lanNetworks: IPv4 only";
      }
    ];

    # ---- ipp-usb ----
    environment.etc."ipp-usb/ipp-usb.conf".text = ''
      [network]
        http-min-port = ${toString cfg.usbPort}
        http-max-port = ${toString (cfg.usbPort + 1)}
        dns-sd = disable
        interface = loopback
        ipv6 = disable

      [auth uid]
        fax, print, scan = *
        config = root

      [logging]
        device-log = error, info
        main-log = error, info
        console-log = error, info
        console-color = disable
    '';
    environment.systemPackages = [ pkgs.ipp-usb ];
    # 71-ipp-usb.rules: a 7/1/4 device (or the HP 255/9/1 ones) gets
    # root:lp 0664 and SYSTEMD_WANTS=ipp-usb.service.
    services.udev.packages = [ pkgs.ipp-usb ];
    systemd.services.ipp-usb = {
      description = "IPP over USB for the home printer (loopback only)";
      after = [ "cups.service" ];
      restartTriggers = [ config.environment.etc."ipp-usb/ipp-usb.conf".source ];
      serviceConfig = {
        ExecStart = "${lib.getExe pkgs.ipp-usb} udev";
        # Device plugged in: create the queue now, not at the next 15 min
        # tick (+: systemctl needs privileges the sandbox drops).
        ExecStartPost = "+${pkgs.systemd}/bin/systemctl --no-block restart lan-printer-${q}.timer";
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 5;
        StateDirectory = "ipp-usb";
        LogsDirectory = "ipp-usb";
        # nixpkgs' services.ipp-usb hardening, plus loopback-only IP.
        ProtectHome = true;
        PrivateTmp = true;
        PrivateUsers = true;
        ProtectControlGroups = true;
        MemoryDenyWriteExecute = true;
        # USB device nodes only (/dev/bus/usb/*, major usb_device).
        DevicePolicy = "closed";
        DeviceAllow = [ "char-usb_device rw" ];
        # nixpkgs: ProtectClock breaks the daemon (its implied DeviceAllow
        # for /dev/rtc closes the device list); kept off like there.
        ProtectClock = false;
        ProtectKernelTunables = true;
        ProtectKernelLogs = true;
        ProtectSystem = "strict";
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        PrivateMounts = true;
        ProtectHostname = true;
        ProtectKernelModules = true;
        RemoveIPC = true;
        RestrictNamespaces = true;
        AmbientCapabilities = "";
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_NETLINK"
          "AF_INET"
          "AF_INET6"
        ];
        ProtectProc = "noaccess";
        IPAddressDeny = "any";
        IPAddressAllow = "localhost";
      };
    };

    # ---- CUPS, shared to the LAN ----
    services.printing = {
      enable = true;
      listenAddresses = [
        "localhost:631"
        "${cfg.lanAddress}:631"
      ];
      # allowFrom stays localhost for /, /admin and /admin/conf.
      webInterface = false;
      browsing = false;
      defaultShared = false;
      browsed.enable = false;
      extraConf = lib.mkAfter ''
        # Unauthenticated LAN (see the header): no job files kept, short
        # job history, the LAN gets only the ops of policy `lan`.
        PreserveJobFiles No
        PreserveJobHistory 15m
        DefaultPolicy lan
        # Overrides nixpkgs' `DefaultAuthType Basic` (mkAfter: last wins).
        # cupsd runs PAM on ANY request carrying `Authorization: Basic`
        # when the default type is Basic, before the policy, so even an
        # allowed Get-Printer-Attributes from the LAN would be a password
        # oracle. Root and local users authenticate over the local socket
        # (PeerCred/Local certificates), which ignores this.
        DefaultAuthType None

        <Location /printers/${q}>
          Order allow,deny
          Allow localhost
          ${lib.concatMapStrings (n: "Allow ${n}\n  ") cfg.lanNetworks}
        </Location>

        <Policy lan>
          # Job names/users hidden from everyone: the owner and @SYSTEM
          # checks here take the spoofable requesting-user-name, and the
          # queue has no ACL.
          JobPrivateAccess @ACL
          JobPrivateValues default
          SubscriptionPrivateAccess @ACL
          SubscriptionPrivateValues default

          # Printing and status, from the LAN too; no auth.
          <Limit ${ops lanOps}>
            Order deny,allow
          </Limit>

          # The owner's job ops: localhost only.
          <Limit ${ops ownerOps}>
            Require user @OWNER @SYSTEM
            Order deny,allow
            Deny all
            Allow localhost
          </Limit>

          # Admin: localhost only (403 from anywhere else, never 401).
          # AuthType Basic here only names the challenge for local
          # clients; Basic itself is off (DefaultAuthType None).
          <Limit ${ops adminOps}>
            AuthType Basic
            Require user @SYSTEM
            Order deny,allow
            Deny all
            Allow localhost
          </Limit>

          # Named explicitly (see localOnlyOps), then everything else
          # (Print-URI, CUPS-Get-Devices, CUPS-Get-PPDs, subscriptions,
          # ...): localhost only.
          <Limit ${ops localOnlyOps}>
            Order deny,allow
            Deny all
            Allow localhost
          </Limit>

          <Limit All>
            Order deny,allow
            Deny all
            Allow localhost
          </Limit>
        </Policy>
      '';
      # No notifiers that reach out: rss:// GETs/PUTs a feed on any host
      # (SSRF), mailto: runs sendmail; dbus (local bus) stays. Load-bearing
      # beside the policy: a LAN Print-Job/Create-Job may carry its own
      # subscription (notify-recipient-uri), which no <Limit> covers.
      # Only cups ships lib/cups/notifier, so buildEnv may link it as one
      # symlink: unfold it first.
      bindirCmds = ''
        n=$out/lib/cups/notifier
        if [ -L "$n" ]; then
          t=$(readlink -f "$n")
          rm "$n"
          mkdir "$n"
          ln -s "$t"/* "$n"/
        fi
        rm -f "$n/rss" "$n/mailto"
      '';
    };
    # The LAN alias may come up after the socket.
    systemd.sockets.cups.socketConfig.FreeBind = true;
    # Password checks only for localhost peers. cupsd authenticates a
    # request (PAM) before it applies <Location> address rules, and
    # nixpkgs' <Location /admin/conf> keeps `AuthType Basic`, so a LAN
    # request there with Basic credentials would still be a password
    # oracle. cupsd sets PAM_RHOST to the peer's address ("localhost" on
    # the socket); anything else fails here before pam_unix looks at the
    # password. Local admin uses PeerCred/certificates, not PAM.
    security.pam.services.cups.rules.auth.lan-printer-localhost-only = {
      order = 10000;
      control = "requisite";
      modulePath = "${config.security.pam.package}/lib/security/pam_succeed_if.so";
      args = [
        "quiet"
        "rhost"
        "in"
        "localhost:127.0.0.1"
      ];
    };

    hyper.lanPrinter = {
      enable = true;
      name = q;
      uri = "ipp://localhost:${toString cfg.usbPort}/ipp/print";
      description = "Home printer (USB)";
      location = "Home";
      shared = true;
      makeDefault = true;
      defaults = {
        PageSize = "A4";
        media = "iso_a4_210x297mm";
        # Also on a queue created before DefaultPolicy was `lan`.
        printer-op-policy = "lan";
      };
    };

    networking.firewall.extraCommands = lib.mkIf (!config.networking.nftables.enable) (
      lib.concatMapStrings (net: ''
        iptables -A nixos-fw ${iptIf} -p tcp -d ${cfg.lanAddress} --dport 631 -s ${net} -j nixos-fw-accept
      '') cfg.lanNetworks
    );
    networking.firewall.extraInputRules = lib.mkIf config.networking.nftables.enable ''
      ${nftIf} ip saddr { ${lib.concatStringsSep ", " cfg.lanNetworks} } ip daddr ${cfg.lanAddress} tcp dport 631 accept
    '';

    # ---- scanning via ipp-usb's eSCL ----
    hyper.scanTrigger = {
      enable = lib.mkDefault true;
      printerAddress = lib.mkDefault "localhost";
      printerPort = lib.mkDefault cfg.usbPort;
      listenAddress = lib.mkDefault cfg.lanAddress;
      interface = lib.mkDefault cfg.interface;
      allowedNetworks = lib.mkDefault cfg.lanNetworks;
    };
  };
}
