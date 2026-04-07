{pkgs, ...}: {
  # Enable NUT (Network UPS Tools)
  power.ups = {
    enable = true;
    mode = "standalone";

    # Define your UPS
    ups."zircon" = {
      driver = "nutdrv_qx";
      port = "auto";
      description = "Zircon Pi-1200";
      directives = [
        "vendorid = 0001"
        "productid = 0000"
      ];
    };

    # Define users with command permissions
    users = {
      admin = {
        passwordFile = builtins.toFile "upsmon-pw" "admin";
        actions = [ "SET" ];
        instcmds = [ "ALL" ];
      };
      # User for upsmon to connect
      upsmon = {
        passwordFile = builtins.toFile "upsmon-pw" "secret";
        upsmon = "primary";
      };
    };

    # Configure upsd to listen on localhost
    upsd = {
      enable = true;
      listen = [
        { address = "127.0.0.1"; }
      ];
    };

    # Configure upsmon (required even for standalone)
    upsmon = {
      enable = true;
      monitor."zircon" = {
        system = "zircon@localhost";
        user = "upsmon";
        passwordFile = builtins.toFile "upsmon-pw" "secret";
        type = "primary";
        powerValue = 1;
      };
    };
  };

  # Add nut package to system packages
  environment.systemPackages = with pkgs; [
    nut
  ];
}
