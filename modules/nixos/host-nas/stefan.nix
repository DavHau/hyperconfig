{pkgs, ...}: {
  security.sudo.extraRules = [
    {
      users = [ "stefan" ];
      commands = [ { command = "${pkgs.systemd}/bin/systemctl restart voicinator"; options = [ "SETENV" "NOPASSWD" ]; } ];
    }
  ];
}
