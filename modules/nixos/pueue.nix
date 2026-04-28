{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.pueue ];
  systemd.user.services.pueued = {
    description = "Pueue Daemon - CLI process scheduler and manager";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.pueue}/bin/pueued -v";
      Restart = "on-failure";
    };
  };
}
