# dave's hermes agent on som, in its OWN account `dave-hermes` (not the
# dave login: the agent is untrusted and native mode gives it everything
# the owning uid has). Same shape as ./stefan-hermes.nix: runs NATIVE
# (services.hermes-microvm users.<n>.native, spaces
# modules/nixos/hermes/native.nix) - host units hermes-agent-dave-hermes /
# hermes-dashboard-dave-hermes as the dave-hermes account, no microVM.
# Brain: p0's Qwen (the common initialModel in ./hermes-common.nix; seeded
# once into the fresh state under /var/lib/hermes-microvm/dave-hermes/
# state-vault). No OpenRouter, no Telegram: driven over SSH (hermes CLI)
# and the web dashboard.
#
# dave's own account keeps whatever the spaces desktop profile
# auto-provisions for it (a VM on som); this file does not touch it.
{ config, pkgs, inputs, ... }:
let
  # The hermes-desktop on amy dials this account over ssh (spaces' SSH
  # connection kind; hermes/desktop-connections.nix on amy owns the key
  # and the rationale). Public half from amy's vars; the app's bootstrap
  # needs command execution plus one loopback -L forward to the port its
  # `hermes serve --port 0` picks, nothing else: no pty (the desktop's
  # remote terminal tab is not served), no agent/X11 forwarding.
  desktopKey = inputs.self.nixosConfigurations.amy.config.clan.core.vars.generators.hermes-desktop-ssh.files."key.pub".value;
in
{
  imports = [ ./hermes-common.nix ];

  # The spaces desktop profile auto-provisions every normal user, which
  # merges with the hyper.hermes entry below. uid pinned: native mode
  # binds the dashboard backend at 20000 + uid, and
  # ./hermes-dashboard-public.nix needs that port as a constant.
  users.users.dave-hermes = {
    isNormalUser = true;
    uid = 1005;
    description = "dave's hermes agent";
    # Read-only on /vault/parquet (./vault-ids.nix).
    extraGroups = [ "vault-ro" ];
    # SSH login (hermes CLI over ssh): the clan admin role fills root's
    # list, reuse it (same as ./users/momentum-vault.nix). Plus amy's
    # desktop key, restricted.
    openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys ++ [
      ''restrict,port-forwarding,permitopen="127.0.0.1:*" ${desktopKey}''
    ];
    # Not the site default fish: hermes-desktop's SSH connection kind runs
    # its remote probe and `hermes serve` as POSIX sh one-liners
    # (`help="$(...)"`) in the login shell, which fish rejects.
    shell = pkgs.bash;
  };

  hyper.hermes.users.dave-hermes = {
    native = true;
    openrouter = false;
  };

  # Web dashboard at https://hermes.davhau.com/ for the pocket-id account
  # `dave` (./hermes-dashboard-public.nix; passkey, enroll with
  # pocket-id-enroll on edi).
  hyper.hermesDashboard.users.dave-hermes.account = "dave";

  # oh-my-pi on p0's Qwen: models.yml (./omp-common.nix) resolves the key
  # through `p0-api-key`, which reads the per-user copy this installs at
  # /run/inference-api-key/dave-hermes/token (./inference-api-key.nix).
  hyper.inferenceApiKey.users = [ "dave-hermes" ];
}
