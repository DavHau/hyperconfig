{ pkgs, inputs, ... }:
let
  udiskie = (inputs.wrappers.wrapperModules.udiskie.apply {
    inherit pkgs;
  }).wrapper;
in {
  environment.systemPackages = [ udiskie ];

  systemd.user.services.udiskie = {
    description = "udiskie automount daemon";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${udiskie}/bin/udiskie --tray";
      Restart = "on-failure";
    };
  };
}
