{pkgs, config, ...}: {

  environment.systemPackages = [
    # program to enter password by hand to be stored in temporary memory
    (pkgs.writeScriptBin
      "enter-password"
      (builtins.readFile ./enter-password.sh))
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
      passwd=$(curl -su admin:$(cat ${config.sops.secrets.tasmota-pw.path}) "http://192.168.20.31/cm?cmnd=var16" | jq '.Var16' -r)
      for ds in pool11/enc rpool/enc; do
        echo $passwd | zfs load-key $ds && echo "key loaded successfully for $ds"
      done
      zfs mount -a
      echo "all datasets mounted successfully"
    '';
  };
}
