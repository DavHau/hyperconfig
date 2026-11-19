{pkgs, ...}: let
  roots = ["pool11/enc" "rpool/enc"];
  rootsStr = builtins.concatStringsSep " " roots;
in {
  # The ZFS passphrase of pool11/enc and rpool/enc, kept in the clan vars
  # store only (deploy = false): manual recovery, and the input of the
  # planned clevis/tang binding (branch nas-tang). Entered once by Dave:
  #     clan vars set nas zfs-passphrase/passphrase
  clan.core.vars.generators.zfs-passphrase = {
    prompts.passphrase = {
      type = "hidden";
      persist = true;
      description = "ZFS passphrase of pool11/enc and rpool/enc";
    };
    files.passphrase.deploy = false;
  };

  # Until nas-tang lands, the keys are loaded by hand after a boot:
  #     ssh -t root@nas.d enter-password
  # It prompts once for the passphrase, loads it into both roots and
  # restarts automount. The former key store, Var16 of the Tasmota at
  # 192.168.20.31, is gone: that device runs ESPHome since 2026-11-01
  # (locations/casa/esphome/rolladen-gz.yaml; it now serves tang).
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "enter-password";
      runtimeInputs = [pkgs.zfs pkgs.systemd];
      text = ''
        for ds in ${rootsStr}; do
          if [ "$(zfs get -H -o value keystatus "$ds")" = available ]; then
            echo "$ds: key already loaded"
            continue
          fi
          if [ -z "''${passwd+x}" ]; then
            read -rsp "ZFS passphrase (${rootsStr}): " passwd
            echo
          fi
          printf '%s' "$passwd" | zfs load-key "$ds"
          echo "$ds: key loaded"
        done
        systemctl restart automount
      '';
    })
  ];

  # Mounts the encrypted datasets once their keys are loaded. Succeeds when
  # they are (already mounted is fine); fails, saying how to unlock, when not.
  systemd.services.automount = {
    description = "Automount Encrypted Dataset";
    wantedBy = ["multi-user.target"];
    serviceConfig.Type = "oneshot";
    path = [pkgs.zfs];
    script = ''
      set -eu
      locked=()
      for ds in ${rootsStr}; do
        [ "$(zfs get -H -o value keystatus "$ds")" = available ] || locked+=("$ds")
      done
      if [ ''${#locked[@]} -gt 0 ]; then
        echo "keys not loaded for: ''${locked[*]}; unlock with: ssh -t root@nas.d enter-password" >&2
        exit 1
      fi
      zfs mount -a
      for ds in ${rootsStr}; do
        if [ "$(zfs get -H -o value mounted "$ds")" != yes ]; then
          echo "$ds: key loaded but not mounted" >&2
          exit 1
        fi
      done
      echo "all encrypted datasets mounted"
    '';
  };
}
