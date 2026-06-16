{ config, pkgs, lib, ... }:
let
  # The agent runs as a systemd user service without a TTY, so PIN prompts go
  # through SSH_ASKPASS. The wrapper resolves the wayland/X display at prompt
  # time because the socket-activated agent may start before the compositor
  # has imported its environment (or survive a compositor restart).
  askpass = pkgs.writeShellScript "ssh-tpm-askpass" ''
    eval "$(${pkgs.systemd}/bin/systemctl --user show-environment \
      | ${pkgs.gnugrep}/bin/grep -E '^(WAYLAND_DISPLAY|DISPLAY|XAUTHORITY)=' \
      | ${pkgs.gnused}/bin/sed 's/^/export /')"
    exec ${pkgs.seahorse}/libexec/seahorse/ssh-askpass "$@"
  '';
in
{
  # TPM-backed ssh keys via https://github.com/Foxboron/ssh-tpm-agent
  #
  # Create a key once with:
  #   ssh-tpm-keygen          # prompts for a PIN; writes ~/.ssh/id_ecdsa.tpm + .pub
  # The private key is sealed to this machine's TPM and useless elsewhere.
  # The agent fronts the regular ssh-agent (started by ./ssh.nix): TPM keys
  # are served by the TPM, every other request is proxied through.

  security.tpm2.enable = true;

  # Access to /dev/tpmrm0 requires tss group membership. This module is shared
  # across laptops whose primary interactive user differs (grmpf on amy, dave
  # on vit), so grant every normal user rather than hardcoding one.
  users.groups.${config.security.tpm2.tssGroup}.members =
    builtins.attrNames (lib.filterAttrs (_: u: u.isNormalUser) config.users.users);

  environment.systemPackages = [ pkgs.ssh-tpm-agent ];

  systemd.user.sockets.ssh-tpm-agent = {
    description = "SSH TPM agent socket";
    wantedBy = [ "sockets.target" ];
    socketConfig = {
      ListenStream = "%t/ssh-tpm-agent.sock";
      SocketMode = "0600";
      Service = "ssh-tpm-agent.service";
    };
  };

  systemd.user.services.ssh-tpm-agent = {
    description = "ssh-tpm-agent service";
    documentation = [ "https://github.com/Foxboron/ssh-tpm-agent" ];
    requires = [ "ssh-tpm-agent.socket" ];
    after = [ "ssh-tpm-agent.socket" ];
    environment = {
      SSH_ASKPASS = "${askpass}";
      SSH_ASKPASS_REQUIRE = "force";
    };
    serviceConfig = {
      # --no-cache: prompt for the PIN on every signature instead of caching
      # it in the kernel keyring for the lifetime of the agent.
      ExecStart = "${pkgs.ssh-tpm-agent}/bin/ssh-tpm-agent --no-cache -A %t/ssh-agent";
      SuccessExitStatus = "2";
    };
  };

  # Point clients at the TPM agent instead of the plain ssh-agent socket set
  # in ./ssh.nix; non-TPM keys still work because the agent proxies to it.
  environment.variables.SSH_AUTH_SOCK = lib.mkForce "$XDG_RUNTIME_DIR/ssh-tpm-agent.sock";
}
