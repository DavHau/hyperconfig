# ssh client defaults on Dave's desktops: agent, connection multiplexing,
# and jump hosts for clan's build machines.
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
  # ssh does not create the ControlPath directory: without it every ssh
  # that tries to become a master fails ("unix_listener: cannot bind ...")
  # and the remote end sees the connection closed (som's borg job to nas).
  # Root's is made here for every machine using this config; agent users
  # make their own (agent-user.nix, machines/som/hermes-agents.nix).
  systemd.tmpfiles.rules = [ "d /root/.ssh/control 0700 root root -" ];
  programs.mtr.enable = true;

  # ssh server
  # services.openssh.enable = true;  # enabled in common.nix
  services.openssh.settings.PasswordAuthentication = false;
  services.openssh.settings.KbdInteractiveAuthentication = false;

  environment.variables = {
    SSH_AUTH_SOCK = "$XDG_RUNTIME_DIR/ssh-agent";
  };
}
