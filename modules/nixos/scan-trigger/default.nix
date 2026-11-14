# scan-trigger: a LAN web page that pulls flatbed scans from a network
# MFP over eSCL (AirScan), builds one searchable PDF per document
# (img2pdf -> ocrmypdf, Tesseract languages incl. Thai) and files it into
# the owner's directory, e.g. bam's /vault/misc/scans/YYYY/ (Canon MF272dw:
# it has no ADF, no scan-to-folder; the PC has to pull, see
# docs/printer-mf272dw.md).
#
# Three units, three users:
#   scan-trigger.service  user scan-trigger (system, unprivileged, no
#     access to the vault). Web UI + eSCL client (./scan_trigger.py).
#     Pages wait in /var/lib/scan-trigger/current/ (survive crashes); a
#     finished PDF goes into the outbox /var/lib/scan-outbox
#     (root:scan-outbox 2770, no sticky bit: scan-trigger can add files
#     but not chmod the directory, and the owner can unlink them).
#   scan-ocr@.service  per connection of scan-ocr.socket (only group
#     scan-trigger may connect): img2pdf + ocrmypdf on the printer's
#     JPEGs (./scan_ocr.py), the part that parses untrusted data. Dynamic
#     user, no network (PrivateNetwork; AF_UNIX only for ocrmypdf's
#     forkserver, with /run, /var/lib and /nix/var hidden so no host
#     socket is reachable), no /vault, no W+X memory, MemoryMax,
#     RuntimeMaxSec; one at a time.
#   scan-deliver.service  user = cfg.owner with the scan-outbox group only
#     as a unit supplementary group: copies each outbox PDF to
#     <outputDir>/<YYYY>/ as a fresh 0600 file of the owner, without
#     ACLs, and unlinks it (./scan_deliver.py: size cap, %PDF- check,
#     never files a name twice). It waits while cfg.requireMount isn't
#     mounted (bam's vault datasets are nofail mounts) and never creates
#     anything on the placeholder below it, and while a scan would leave
#     less than minFreeBytes on outputDir or exceed dailyBytes (the
#     vault dataset is shared; a compromised scan service can't fill it).
#
# Resource limits: eSCL replies <= 64 MiB per page within downloadSeconds,
# maxPages per document, no scan below minFreeBytes free or with
# outboxMaxBytes waiting, documents <= maxDocBytes, OCR <= ocrTimeout.
#
# Exposure: listens on cfg.listenAddress only (bam: the static LAN alias
# 192.168.8.250), the firewall opens the port only for
# cfg.allowedNetworks (on cfg.interface), the unit's IPAddressAllow
# repeats that plus the printer, and the app checks peer, Host header, Sec-Fetch-Site/Origin and
# a per-start form token. Nothing goes through a proxy or the tailnet.
# Local processes on the host reach the page via lo with a LAN source
# address and so have a LAN client's rights.
# Test: ./test.nix (fake eSCL scanner with German/English/Thai text).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.scanTrigger;
  inherit (lib) mkOption types;

  tesseract = pkgs.tesseract5.override {
    # osd: --rotate-pages
    enableLanguages = lib.unique (
      cfg.languages
      ++ [
        "eng"
        "osd"
      ]
    );
  };
  ocrmypdf = pkgs.python3Packages.toPythonApplication (
    (pkgs.python3Packages.ocrmypdf.override { inherit tesseract; }).overridePythonAttrs {
      # Its test suite runs against the full tesseract; ours only differs
      # in the bundled language files.
      doCheck = false;
    }
  );

  outbox = "/var/lib/scan-outbox";
  stateDir = "/var/lib/scan-trigger";
  deliverStateDir = "/var/lib/scan-deliver";
  ocrSocket = "/run/scan-ocr/ocr.sock";

  conf = pkgs.writeText "scan-trigger.json" (
    builtins.toJSON {
      inherit stateDir;
      outboxDir = outbox;
      esclUrl = cfg.esclUrl;
      allowedNetworks = cfg.allowedNetworks;
      hostNames = cfg.hostNames;
      listenAddress = cfg.listenAddress;
      inherit (cfg)
        port
        defaultResolution
        resolutions
        languages
        outputType
        ocrArgs
        historySize
        outputDir
        requireMount
        ;
      outputLabel = "${cfg.outputDir}/<year>/";
      img2pdf = lib.getExe pkgs.img2pdf;
      ocrmypdf = lib.getExe ocrmypdf;
      inherit ocrSocket deliverStateDir;
      inherit (cfg)
        maxPages
        minFreeBytes
        outboxMaxBytes
        dailyBytes
        maxDocBytes
        ocrTimeout
        ocrJobs
        ;
      maxPageBytes = 64 * 1024 * 1024;
      downloadSeconds = 300;
      img2pdfTimeout = 300;
      pollSeconds = 5;
    }
  );

  python = pkgs.python3;
  iptIf = lib.optionalString (cfg.interface != null) "-i ${cfg.interface}";
  nftIf = lib.optionalString (cfg.interface != null) "iifname \"${cfg.interface}\"";

  sandbox = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    ProcSubset = "pid";
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
    ];
    SystemCallErrorNumber = "EPERM";
    CapabilityBoundingSet = "";
  };
  hardening = sandbox // {
    Restart = "always";
    RestartSec = 5;
  };
in
{
  options.hyper.scanTrigger = {
    enable = lib.mkEnableOption "the LAN scan-trigger page for an eSCL scanner";

    printerAddress = mkOption {
      type = types.str;
      example = "192.168.18.20";
      description = "IP address (or name) of the scanner/MFP.";
    };
    esclUrl = mkOption {
      type = types.str;
      default = "http://${cfg.printerAddress}/eSCL";
      defaultText = lib.literalExpression ''"http://''${printerAddress}/eSCL"'';
      description = "eSCL base URL (Canon MF27x: http://<ip>/eSCL; https:// also works, the self-signed cert is not checked).";
    };

    listenAddress = mkOption {
      type = types.str;
      example = "192.168.8.250";
      description = "LAN address the page listens on (bound with IP_FREEBIND, so it may come up later).";
    };
    port = mkOption {
      type = types.port;
      default = 8088;
    };
    hostNames = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "bam.lan" ];
      description = "Host names the page answers to besides listenAddress (Host header check against DNS rebinding).";
    };
    interface = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "br0";
      description = "Open the firewall port only on this interface (null: any).";
    };
    allowedNetworks = mkOption {
      type = types.listOf types.str;
      default = [ "192.168.8.0/24" ];
      description = "IPv4 client networks allowed to open the page (firewall, unit IP filter and app check).";
    };

    languages = mkOption {
      type = types.listOf types.str;
      default = [
        "deu"
        "eng"
        "tha"
      ];
      description = "Tesseract languages for OCR (order = priority).";
    };
    outputType = mkOption {
      type = types.enum [
        "pdf"
        "pdfa"
      ];
      default = "pdf";
      description = "ocrmypdf --output-type. `pdf` keeps the scanned JPEGs as they are; `pdfa` re-encodes through Ghostscript for PDF/A.";
    };
    ocrArgs = mkOption {
      type = types.listOf types.str;
      default = [
        "--rotate-pages"
        "--deskew"
        "--optimize"
        "1"
      ];
      description = "Extra ocrmypdf arguments.";
    };
    resolutions = mkOption {
      type = types.listOf types.int;
      default = [
        150
        300
        600
      ];
    };
    defaultResolution = mkOption {
      type = types.int;
      default = 300;
    };
    historySize = mkOption {
      type = types.int;
      default = 10;
      description = "How many delivered file names the page lists.";
    };

    maxPages = mkOption {
      type = types.ints.positive;
      default = 50;
      description = "Most pages per document.";
    };
    minFreeBytes = mkOption {
      type = types.ints.unsigned;
      default = 2 * 1024 * 1024 * 1024;
      description = "No scan while /var/lib has less free space than this, and no delivery that would leave less than this free on outputDir.";
    };
    outboxMaxBytes = mkOption {
      type = types.ints.positive;
      default = 2 * 1024 * 1024 * 1024;
      description = "No scan while this much waits in the outbox (vault not mounted).";
    };
    dailyBytes = mkOption {
      type = types.ints.positive;
      default = 2 * 1024 * 1024 * 1024;
      description = "Most bytes the delivery files into outputDir per day; the rest waits in the outbox.";
    };
    maxDocBytes = mkOption {
      type = types.ints.positive;
      default = 512 * 1024 * 1024;
      description = "Largest PDF the OCR worker may return and the delivery accepts (50 pages at 600 dpi colour fit).";
    };
    ocrTimeout = mkOption {
      type = types.ints.positive;
      default = 600;
      description = "Seconds img2pdf+ocrmypdf may take for one document.";
    };
    ocrJobs = mkOption {
      type = types.ints.positive;
      default = 2;
      description = "ocrmypdf --jobs (pages OCRed in parallel; memory scales with it).";
    };
    ocrMemoryMax = mkOption {
      type = types.str;
      default = "2G";
      description = "MemoryMax of the OCR worker (a 600 dpi colour A4 page with ocrJobs = 2 fits).";
    };

    owner = mkOption {
      type = types.str;
      example = "dave";
      description = "User who owns the delivered files (mode 0600) and runs the delivery.";
    };
    outputDir = mkOption {
      type = types.str;
      example = "/vault/misc/scans";
      description = "Directory below which <YYYY>/<YYYY-MM-DD_HHMMSS>.pdf are filed (created 0700 by the owner).";
    };
    requireMount = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/vault/misc";
      description = "Deliver only while this path is a mount point; until then scans wait in the outbox.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # A document between dailyBytes and maxDocBytes could never pass
        # the daily budget and would hold up the queue behind it forever.
        assertion = cfg.dailyBytes >= cfg.maxDocBytes;
        message = "hyper.scanTrigger.dailyBytes must be >= maxDocBytes";
      }
      {
        assertion = lib.elem cfg.defaultResolution cfg.resolutions;
        message = "hyper.scanTrigger.defaultResolution must be one of resolutions";
      }
      {
        assertion = lib.all (n: !(lib.hasInfix ":" n)) cfg.allowedNetworks;
        message = "hyper.scanTrigger.allowedNetworks: IPv4 only";
      }
    ];

    users.users.scan-trigger = {
      isSystemUser = true;
      group = "scan-trigger";
      extraGroups = [ "scan-outbox" ];
    };
    users.groups.scan-trigger = { };
    # Members: scan-trigger only. The owner gets it per unit
    # (SupplementaryGroups below), not in his login sessions.
    users.groups.scan-outbox = { };

    # root-owned, so scan-trigger can't chmod it to lock the owner's
    # delivery out; no sticky bit, so the owner (via the group) can unlink
    # scan-trigger's files. `d` also fixes owner/mode of an existing dir.
    systemd.tmpfiles.settings.scan-trigger = {
      ${outbox}.d = {
        user = "root";
        group = "scan-outbox";
        mode = "2770";
      };
    };

    systemd.sockets.scan-ocr = {
      description = "OCR worker for the scan page";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = ocrSocket;
        Accept = true;
        MaxConnections = 1;
        SocketUser = "root";
        SocketGroup = "scan-trigger";
        SocketMode = "0660";
        DirectoryMode = "0755";
      };
    };

    systemd.services."scan-ocr@" = {
      description = "OCR of one scanned document (no network)";
      serviceConfig = sandbox // {
        ExecStart = "${python.interpreter} ${./scan_ocr.py} ${conf}";
        StandardInput = "socket";
        StandardOutput = "socket";
        StandardError = "journal";
        DynamicUser = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateUsers = true;
        PrivateIPC = true;
        PrivateNetwork = true;
        IPAddressDeny = "any";
        # AF_UNIX: ocrmypdf's ProcessPoolExecutor (Python 3.14's default
        # forkserver) talks over a socketpair. Hide every world-
        # connectable socket path on the host instead (dbus, nscd,
        # journal, nix-daemon, services' state dirs); abstract sockets are
        # per netns (PrivateNetwork). It only uses its inherited fds.
        RestrictAddressFamilies = "AF_UNIX";
        TemporaryFileSystem = [ "/run" ];
        InaccessiblePaths = [
          "-/var/lib"
          "-/nix/var"
          "-/vault"
        ];
        MemoryDenyWriteExecute = true;
        SystemCallFilter = [
          "@system-service"
          "~@privileged @mount @clock @debug @module @raw-io @reboot @swap @cpu-emulation @obsolete"
        ];
        UMask = "0077";
        Environment = [
          "HOME=/tmp"
          "TMPDIR=/tmp"
          "XDG_CACHE_HOME=/tmp/cache"
          "OMP_THREAD_LIMIT=1"
        ];
        MemoryMax = cfg.ocrMemoryMax;
        MemorySwapMax = 0;
        TasksMax = 64;
        RuntimeMaxSec = cfg.ocrTimeout + 60;
        Nice = 5;
      };
    };

    systemd.services.scan-trigger = {
      description = "LAN scan page (eSCL pull, OCR)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = hardening // {
        ExecStart = "${python.interpreter} ${./scan_trigger.py} ${conf}";
        User = "scan-trigger";
        Group = "scan-trigger";
        StateDirectory = "scan-trigger";
        Environment = [
          "HOME=${stateDir}"
          "XDG_CACHE_HOME=${stateDir}/cache"
        ];
        StateDirectoryMode = "0700";
        ReadWritePaths = [ outbox ];
        InaccessiblePaths = [ "-/vault" ];
        ProtectSystem = "strict";
        ProtectHome = true;
        UMask = "0077";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_UNIX"
        ];
        IPAddressDeny = "any";
        IPAddressAllow =
          cfg.allowedNetworks
          ++ [ "localhost" ]
          ++ lib.optional (builtins.match "[0-9.]+" cfg.printerAddress != null) cfg.printerAddress;
        # Holds one page (<= 64 MiB) at a time; OCR runs in scan-ocr@.
        MemoryMax = "512M";
        TasksMax = 64;
        Nice = 5;
      };
    };

    systemd.services.scan-deliver = {
      description = "File finished scans into ${cfg.outputDir}";
      wantedBy = [ "multi-user.target" ];
      after = [
        # The outbox must be root-owned before we trust it.
        "systemd-tmpfiles-setup.service"
        "local-fs.target"
        "remote-fs.target"
      ];
      serviceConfig = hardening // {
        ExecStart = "${python.interpreter} ${./scan_deliver.py} ${conf}";
        User = cfg.owner;
        SupplementaryGroups = [ "scan-outbox" ];
        # budget.json: bytes filed today.
        StateDirectory = "scan-deliver";
        StateDirectoryMode = "0700";
        # Not `strict` + ReadWritePaths: that bind-mounts the (possibly
        # not yet mounted) placeholder of a nofail dataset into the unit's
        # namespace. `full` leaves the rest writable by plain modes only.
        ProtectSystem = "full";
        ProtectHome = true;
        PrivateNetwork = true;
        RestrictAddressFamilies = "none";
        UMask = "0077";
        MemoryMax = "256M";
      };
    };

    networking.firewall.extraCommands = lib.mkIf (!config.networking.nftables.enable) (
      lib.concatMapStrings (net: ''
        iptables -A nixos-fw ${iptIf} -p tcp -d ${cfg.listenAddress} --dport ${toString cfg.port} -s ${net} -j nixos-fw-accept
      '') cfg.allowedNetworks
    );
    networking.firewall.extraInputRules = lib.mkIf config.networking.nftables.enable ''
      ${nftIf} ip saddr { ${lib.concatStringsSep ", " cfg.allowedNetworks} } ip daddr ${cfg.listenAddress} tcp dport ${toString cfg.port} accept
    '';
  };
}
