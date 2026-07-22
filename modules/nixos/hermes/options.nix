# Option interface of services.hermes-microvm, plus the assertions that
# validate it (uids must be unique — they derive ports, MAC and firewall
# identity; secretEnv names ride qemu fw_cfg and are length-limited).
{ config, lib, pkgs, ... }:
let
  cfg = config.services.hermes-microvm;
in
{
  options.services.hermes-microvm = with lib; {
    enable = mkEnableOption "per-user Hermes agent MicroVMs";

    settings = mkOption {
      type = types.attrs;
      default = { };
      description = "Hermes settings, passed to the upstream module in every guest.";
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Non-secret env vars for every guest's hermes .env.";
    };

    extraPlugins = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Hermes plugin packages, installed in every guest.";
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Guest packages on the agent's PATH, in addition to the built-in toolset.";
    };

    pythonPackages = mkOption {
      type = types.functionTo (types.listOf types.package);
      description = "Python libraries preinstalled in every guest's writable venv.";
      default = ps: with ps; [
        # math / data (openblas-accelerated), CPU torch (AVX-512), numba JIT
        numpy
        scipy
        sympy
        pandas
        polars
        pyarrow
        duckdb
        matplotlib
        seaborn
        scikit-learn
        statsmodels
        networkx
        numba
        pillow
        tqdm
        # ML
        torch
        transformers
        # research / documents
        pypdf
        openpyxl
        python-docx
        # (nixpkgs `arxiv` currently fails its runtime-deps check; agents
        # can `pip install arxiv` into the venv when needed)
        wikipedia
        # crawling / web
        requests
        httpx
        aiohttp
        beautifulsoup4
        lxml
        html5lib
        feedparser
        trafilatura
        scrapy
        # misc
        pyyaml
        rich
        ipython
      ];
    };

    vcpu = mkOption {
      type = types.int;
      default = 8;
      description = "vCPUs per guest.";
    };

    mem = mkOption {
      type = types.int;
      default = 8192;
      description = "Guest RAM in MiB.";
    };

    gpu = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Vulkan in every guest via QEMU Venus (virtio-gpu-gl on the host
          iGPU's render node). The GPU is time-shared with the host
          desktop, not passed through.
        '';
      };
      hostmem = mkOption {
        type = types.str;
        default = "4G";
        description = ''
          virtio-gpu hostmem: PCI BAR window for mapped host blobs
          (address space, not a RAM reservation).
        '';
      };
    };

    simplex = {
      enable = mkEnableOption "a SimpleX Chat daemon inside each guest (state on the vault share)";
      allowedUsers = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "SIMPLEX_ALLOWED_USERS passed to hermes (contactIds or display names).";
      };
    };

    users = mkOption {
      default = { };
      description = "Users that get their own Hermes microvm.";
      type = types.attrsOf (types.submodule ({ config, ... }: {
        options = {
          uid = mkOption {
            type = types.int;
            description = "The user's uid on the host (mirrored in the guest).";
          };
          dashboardPort = mkOption {
            type = types.port;
            default = 22100 + config.uid - 1000;
            description = "Host 127.0.0.1 port forwarded to the guest dashboard.";
          };
          spacesPort = mkOption {
            type = types.port;
            default = 22200 + config.uid - 1000;
            description = "Host 127.0.0.1 port of the spaces gateway TCP bridge.";
          };
          environment = mkOption {
            type = types.attrsOf types.str;
            default = { };
            description = "Per-user non-secret env vars for the guest's hermes .env.";
          };
          secretEnv = mkOption {
            type = types.attrsOf types.str;
            default = { };
            description = ''
              Env var name -> host file path (raw secret value, no KEY=
              prefix). Each entry rides a systemd credential into the
              guest (qemu fw_cfg) and is rewritten into $HERMES_HOME/.env
              before the agent starts. Names are limited to 28 chars.
            '';
          };
          spacesGateway = {
            enable = mkEnableOption "bridging the user's spaces integration gateway into the VM";
            socket = mkOption {
              type = types.str;
              default = "/run/user/${toString config.uid}/spaces-integration-gateway.sock";
              description = "The per-user spaces gateway socket on the host.";
            };
          };
        };
      }));
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = lib.mapAttrsToList (user: ucfg: {
      assertion = lib.count (u: u.uid == ucfg.uid) (lib.attrValues cfg.users) == 1;
      message = "services.hermes-microvm: duplicate uid ${toString ucfg.uid} (${user}) — uids derive ports, MAC and firewall identity and must be unique";
    }) cfg.users
    ++ lib.concatLists (lib.mapAttrsToList (user: ucfg:
      map (name: {
        assertion = builtins.stringLength name <= 28;
        message = "services.hermes-microvm.users.${user}.secretEnv.${name}: credential names must be <= 28 chars (qemu fw_cfg name limit)";
      }) (lib.attrNames ucfg.secretEnv)) cfg.users);
  };
}
