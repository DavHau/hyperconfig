{ config, pkgs, lib, ... }:
let
  cfg = config.services.sshTpmAgent;

  # ssh-tpm-agent, patched to gate every signature behind a confirmation scoped
  # to (uid, login-session, requesting binary): see ssh-tpm-agent-confirm.patch.
  # A grant is cached per (session, binary) so repeated use from the same
  # terminal/app is silent until it expires; a different binary or a different
  # session re-prompts (the "novel-exe" gate). No new Go dependencies, so the
  # upstream vendorHash is unchanged.
  sshTpmAgent = pkgs.ssh-tpm-agent.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./ssh-tpm-agent-confirm.patch ];
  });

  # SSH_ASKPASS handler for graphical prompts. The agent runs as a TTY-less user
  # service, so GUI prompts go through here; it resolves the wayland/X display at
  # prompt time because the socket-activated agent may start before the
  # compositor exported its environment (or survive a compositor restart).
  #
  # Modes (selected by the agent via SSH_ASKPASS_PROMPT):
  #   choice  -> three-way confirm dialog. Prints temporary|session|deny.
  #   (unset) -> TPM PIN passphrase entry via seahorse.
  # Headless requests never reach this script: the agent prompts for the PIN on
  # the requester's own terminal via systemd-ask-password (SSH/tmux friendly).
  askpass = pkgs.writeShellScript "ssh-tpm-askpass" ''
    eval "$(${pkgs.systemd}/bin/systemctl --user show-environment \
      | ${pkgs.gnugrep}/bin/grep -E '^(WAYLAND_DISPLAY|DISPLAY|XAUTHORITY)=' \
      | ${pkgs.gnused}/bin/sed 's/^/export /')"

    if [ "$SSH_ASKPASS_PROMPT" = choice ]; then
      ttl="''${SSH_TPM_CONFIRM_TTL:-15m}"
      # zenity: OK -> exit 0; the extra button prints its label (and exits 1);
      # Cancel/close -> exit 1 with no output. Map those to the agent's tokens.
      sel="$(${pkgs.zenity}/bin/zenity --question --no-wrap \
        --title "ssh-tpm-agent" --text "$1" \
        --ok-label "Trust $ttl" \
        --extra-button "Trust this session" \
        --cancel-label "Deny")"
      rc=$?
      if [ "$sel" = "Trust this session" ]; then
        echo session
      elif [ "$rc" -eq 0 ]; then
        echo temporary
      else
        echo deny
      fi
      exit 0
    fi

    exec ${pkgs.seahorse}/libexec/seahorse/ssh-askpass "$@"
  '';
in
{
  options.services.sshTpmAgent.confirmTtl = lib.mkOption {
    type = lib.types.str;
    default = "15m";
    example = "8h";
    description = ''
      Lifetime of a "Trust for <ttl>" confirmation grant (and of a headless PIN
      authorisation) before ssh-tpm-agent re-prompts. Go duration syntax
      ("30s", "15m", "1h30m", "8h"). The value is also shown on the dialog
      button. "Trust this session" grants ignore this and live until the
      requesting login session ends or the agent restarts.
    '';
  };

  config = {
    # TPM-backed ssh keys via https://github.com/Foxboron/ssh-tpm-agent
    #
    # Create a key once with:
    #   ssh-tpm-keygen          # prompts for a PIN; writes ~/.ssh/id_ecdsa.tpm + .pub
    # The private key is sealed to this machine's TPM and useless elsewhere.
    # The agent fronts the regular ssh-agent (started by ./ssh.nix): TPM keys
    # are served by the TPM, every other request is proxied through. Every use
    # of a TPM key is gated by a confirmation (see sshTpmAgent above).

    security.tpm2.enable = true;

    # Access to /dev/tpmrm0 requires tss group membership. This module is shared
    # across laptops whose primary interactive user differs (grmpf on amy, dave
    # on vit), so grant every normal user rather than hardcoding one.
    users.groups.${config.security.tpm2.tssGroup}.members =
      builtins.attrNames (lib.filterAttrs (_: u: u.isNormalUser) config.users.users);

    environment.systemPackages = [ sshTpmAgent ];

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
      # systemd-ask-password (headless PIN entry) must be resolvable on PATH.
      path = [ pkgs.systemd ];
      environment = {
        SSH_ASKPASS = "${askpass}";
        SSH_ASKPASS_REQUIRE = "force";
        # Disk-loaded keys can't carry the runtime confirm constraint, so opt
        # every TPM key into the confirmation gate.
        SSH_TPM_CONFIRM_ALL = "1";
        # Lifetime of "Trust for <ttl>" / headless grants.
        SSH_TPM_CONFIRM_TTL = cfg.confirmTtl;
        # auto: graphical dialog when the requester has a display, else a PIN
        # prompt on its terminal. Force with "gui" or "tty".
        SSH_TPM_PROMPT = "auto";
      };
      serviceConfig = {
        # The kernel-keyring PIN cache stays (no --no-cache) because the confirm
        # gate authorises every signature regardless of PIN-cache state; and no
        # RuntimeMaxSec, because the grant TTL + session binding is the bound.
        ExecStart = "${sshTpmAgent}/bin/ssh-tpm-agent -A %t/ssh-agent";
        SuccessExitStatus = "2";
      };
    };

    # Point clients at the TPM agent instead of the plain ssh-agent socket set
    # in ./ssh.nix; non-TPM keys still work because the agent proxies to it.
    environment.variables.SSH_AUTH_SOCK = lib.mkForce "$XDG_RUNTIME_DIR/ssh-tpm-agent.sock";
  };
}
