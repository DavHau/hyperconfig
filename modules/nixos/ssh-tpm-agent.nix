{ config, pkgs, lib, ... }:
let
  cfg = config.services.sshTpmAgent;

  # ssh-tpm-agent, patched to gate every signature behind a confirmation. The
  # dialog lists the requesting process and its ancestors; trusting one of them
  # whitelists that process AND all of its children. See
  # ssh-tpm-agent-package.nix (shared with the ssh-tpm-confirm-cache VM test).
  sshTpmAgent = import ./ssh-tpm-agent-package.nix { inherit pkgs; };

  # The confirm dialog itself (GTK, see ssh-tpm-confirm-dialog.py). Shared with
  # the `ssh-tpm-confirm-dialog-preview` screenshot harness.
  confirmDialog = import ./ssh-tpm-confirm-dialog.nix { inherit pkgs; };

  # SSH_ASKPASS handler for graphical prompts. The agent runs as a TTY-less user
  # service, so GUI prompts go through here; it resolves the wayland/X display at
  # prompt time because the socket-activated agent may start before the
  # compositor exported its environment (or survive a compositor restart).
  #
  # Modes (selected by the agent via SSH_ASKPASS_PROMPT):
  #   choice  -> grant dialog. The agent passes the peer's ancestry in
  #              SSH_TPM_CHOICES (one "pid<TAB>name<TAB>cwd" line per process,
  #              requester first; cwd may be empty for sandboxed peers). The
  #              user picks WHICH process to trust (a list row; the requester
  #              is preselected) and for how long (a button).
  #              Prints "temporary <pid>" | "session <pid>" | "deny".
  #   (unset) -> TPM PIN passphrase entry via seahorse.
  # Headless requests never reach this script: the agent prompts for the PIN on
  # the requester's own terminal via systemd-ask-password (SSH/tmux friendly).
  askpass = pkgs.writeShellScript "ssh-tpm-askpass" ''
    eval "$(${pkgs.systemd}/bin/systemctl --user show-environment \
      | ${pkgs.gnugrep}/bin/grep -E '^(WAYLAND_DISPLAY|DISPLAY|XAUTHORITY)=' \
      | ${pkgs.gnused}/bin/sed 's/^/export /')"

    if [ "$SSH_ASKPASS_PROMPT" = choice ]; then
      # The dialog prints the agent's grant protocol on stdout and always
      # exits 0; a crashed dialog (no output) is treated as a denial.
      answer="$(${confirmDialog}/bin/ssh-tpm-confirm-dialog "$1")"
      echo "''${answer:-deny}"
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
      Lifetime of a "Trust <ttl>" confirmation grant (and of a headless PIN
      authorisation) before ssh-tpm-agent re-prompts. Go duration syntax
      ("30s", "15m", "1h30m", "8h"). The value is also shown on the dialog
      button. A grant applies to the process picked in the dialog and all of
      its children; "Trust forever" ignores the TTL and lives until the
      granted process exits or the agent restarts.
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
        # Lifetime of "Trust <ttl>" / headless grants.
        SSH_TPM_CONFIRM_TTL = cfg.confirmTtl;
        # auto: graphical dialog when the requester has a display, else a PIN
        # prompt on its terminal. Force with "gui" or "tty".
        SSH_TPM_PROMPT = "auto";
      };
      serviceConfig = {
        # The kernel-keyring PIN cache stays (no --no-cache) because the confirm
        # gate authorises every signature regardless of PIN-cache state; and no
        # RuntimeMaxSec, because grants die with the granted process or the TTL.
        ExecStart = "${sshTpmAgent}/bin/ssh-tpm-agent -A %t/ssh-agent";
        SuccessExitStatus = "2";
      };
    };

    # Point clients at the TPM agent instead of the plain ssh-agent socket set
    # in ./ssh.nix; non-TPM keys still work because the agent proxies to it.
    environment.variables.SSH_AUTH_SOCK = lib.mkForce "$XDG_RUNTIME_DIR/ssh-tpm-agent.sock";
  };
}
