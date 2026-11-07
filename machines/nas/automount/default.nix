{pkgs, config, ...}: let
  tasmotaPasswordPath = config.clan.core.vars.generators.tasmota-password.files.password.path;
in {
  # Admin password of the Tasmota device (192.168.20.31) holding the ZFS
  # passphrase in Var16. Per-machine, entered once:
  #     clan vars set nas tasmota-password/password
  # Default file ownership (root, 0400) suffices: both readers run as root.
  # Deployed during activation ("services" phase), before automount starts.
  clan.core.vars.generators.tasmota-password = {
    # A persisted prompt IS the file — no generator script.
    prompts.password = {
      type = "hidden";
      persist = true;
      description = "Tasmota admin password (192.168.20.31, ZFS key store)";
    };
  };

  environment.systemPackages = [
    # program to enter password by hand to be stored in temporary memory
    (pkgs.writeShellScriptBin "enter-password" ''
      export TASMOTA_PW_FILE=${tasmotaPasswordPath}
      exec ${pkgs.bash}/bin/bash ${./enter-password.sh} "$@"
    '')
  ];

  # services that reads the password from temporary memory
  systemd.services.automount = {
    description = "Automount Encrypted Dataset";
    requires = ["network-online.target"];
    after = ["network-online.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig.Type = "oneshot";
    path = with pkgs; [
      curl
      jq
      zfs
    ];
    script = ''
      set -e
      passwd=$(curl -su admin:$(cat ${tasmotaPasswordPath}) "http://192.168.20.31/cm?cmnd=var16" | jq '.Var16' -r)
      for ds in pool11/enc rpool/enc; do
        echo $passwd | zfs load-key $ds && echo "key loaded successfully for $ds"
      done
      zfs mount -a
      echo "all datasets mounted successfully"
    '';
  };
}
