{config, pkgs, ...}: let
  check-zfs-script = pkgs.writeShellScript "check-zfs-script"
    ''
      condition=$(${pkgs.zfs}/bin/zpool status | grep -E 'DEGRADED|FAULTED|OFFLINE|UNAVAIL|REMOVED|FAIL|DESTROYED|corrupt|cannot|unrecover')

      if [ "''${condition}" ]; then
        printf "\n==== ERROR ====\n"
        printf "One of the pools is in one of these statuses: DEGRADED|FAULTED|OFFLINE|UNAVAIL|REMOVED|FAIL|DESTROYED|corrupt|cannot|unrecover!\n"
        printf "$condition"
        exit 1
      fi
    '';
in {
  services.monit.enable = true;
  services.monit.config = ''
    SET DAEMON 120
    set alert hsngrmpf@gmail.com
    include "${config.age.secrets.monit-gmail.path}"
    set httpd unixsocket /var/run/monit.sock
      allow root:root
    CHECK PROGRAM check-zpool-status PATH ${check-zfs-script} TIMEOUT 60 SECONDS
      if status != 0 then alert
  '';
}
