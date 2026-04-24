{lib, config, pkgs, ...}:

let
  cfg = config.services.llama-swap;
  llama-server = lib.getExe' cfg.llama-server-package "llama-server";
in
{
  options.services.llama-swap.llama-server-package = lib.mkOption {
    type = lib.types.package;
    default = pkgs.llama-cpp;
    description = "llama-cpp package providing llama-server.";
  };

  config = {
    # Expose llama-swap via Unix socket for rootless Docker containers
    systemd.services.llama-swap-socket = {
      description = "Unix socket proxy for llama-swap";
      requires = [ "llama-swap.service" ];
      after = [ "llama-swap.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.socat}/bin/socat UNIX-LISTEN:/run/llama-swap.sock,fork,mode=0666 TCP:127.0.0.1:${toString cfg.port}";
      };
    };

    # for debugging add llama-server binary to the PATH
    environment.systemPackages = [
      cfg.llama-server-package
    ];

    # expose llama-swap port to docker containers
    networking.firewall.interfaces."br-+".allowedTCPPorts = [
      cfg.port
    ];

    services.llama-swap = {
      enable = true;
      listenAddress = "0.0.0.0";
      port = 8012;
      settings = {
        # Increase health check timeout to 1 hour to accommodate large model downloads
        healthCheckTimeout = 3600;
        logToStdout = "both";
        # All models in here have to be in GGUF format.
        # Browse https://huggingface.co/unsloth to find more GGUF models.
        models = {
          "qwen3.5:0.8b" = {
            cmd = "${llama-server} -hf unsloth/Qwen3.5-0.8B-GGUF --port \${PORT}";
          };
          "qwen3.5:27b" = {
            cmd = "${llama-server} -hf unsloth/Qwen3.5-27B-GGUF --port \${PORT}";
          };
          "qwen3.5:35b" = {
            cmd = "${llama-server} -hf unsloth/Qwen3.5-35B-A3B-GGUF --port \${PORT}";
          };
          "qwen3.5:122b" = {
            cmd = "${llama-server} -hf unsloth/Qwen3.5-122B-A10B-GGUF:UD-Q3_K_XL --port \${PORT}";
          };
        };
      };
    };

    # fix llama-cpp not able to create cache directory
    systemd.services.llama-swap = {
      environment.XDG_CACHE_HOME = "/var/cache/llama.cpp";
      serviceConfig.CacheDirectory = "llama.cpp";
    };
  };
}
