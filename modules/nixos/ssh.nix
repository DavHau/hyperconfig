{ ... }:
{
  programs.ssh.startAgent = true;
  programs.ssh.agentTimeout = "1h";
  programs.ssh.extraConfig = ''
    # AddKeysToAgent yes

    Host *
      ServerAliveInterval 240
      ControlMaster auto
      ControlPath ~/.ssh/control/%C
      ControlPersist 600
      Compression yes

    Host build01
      ProxyJump tunnel@clan.lol
      Hostname build01.vpn.clan.lol

    Host build02
      ProxyJump tunnel@clan.lol
      Hostname build02.vpn.clan.lol
  '';
  programs.mtr.enable = true;

  # ssh server
  # services.openssh.enable = true;  # enabled in common.nix
  services.openssh.settings.PasswordAuthentication = false;
  services.openssh.settings.KbdInteractiveAuthentication = false;

  environment.variables = {
    SSH_AUTH_SOCK = "$XDG_RUNTIME_DIR/ssh-agent";
  };
}
