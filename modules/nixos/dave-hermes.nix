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
{ config, pkgs, ... }:
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
    # SSH login (hermes CLI over ssh): the clan admin role fills root's
    # list, reuse it (same as ./users/momentum-vault.nix).
    openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys;
    # Not the site default fish: hermes-desktop's SSH connection kind runs
    # its remote probe and `hermes serve` as POSIX sh one-liners
    # (`help="$(...)"`) in the login shell, which fish rejects.
    shell = pkgs.bash;
  };

  hyper.hermes.users.dave-hermes = {
    native = true;
    openrouter = false;
  };

  # Web dashboard at https://hermes.davhau.com/dave-hermes/ (password
  # login, ./hermes-dashboard-public.nix):
  #   clan vars generate som --generator hermes-dashboard-dave-hermes
  #   clan vars get som hermes-dashboard-dave-hermes/password
  hyper.hermesDashboard.users.dave-hermes = { };

  # oh-my-pi on p0's Qwen: models.yml (./omp-common.nix) resolves the key
  # through `p0-api-key`, which reads the per-user copy this installs at
  # /run/inference-api-key/dave-hermes/token (./inference-api-key.nix).
  hyper.inferenceApiKey.users = [ "dave-hermes" ];
}
