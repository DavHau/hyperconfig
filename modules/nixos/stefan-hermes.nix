# stefan's hermes agent on som: runs NATIVE (services.hermes-microvm
# users.<n>.native, spaces modules/nixos/hermes/native.nix) - host units
# hermes-agent-stefan / hermes-dashboard-stefan as the stefan account
# (users/stefan-vault.nix), no microVM. Brain: p0's Qwen (the common
# initialModel in ./hermes-common.nix; seeded once into the fresh state under
# /var/lib/hermes-microvm/stefan/state-vault). No OpenRouter, no Telegram:
# driven over SSH (hermes CLI) and the web dashboard.
{
  imports = [ ./hermes-common.nix ];

  hyper.hermes.users.stefan = {
    native = true;
    openrouter = false;
  };

  # Web dashboard at https://hermes.davhau.com/ for the pocket-id account
  # `stefan` (./hermes-dashboard-public.nix; passkey, enroll with
  # pocket-id-enroll on edi).
  hyper.hermesDashboard.users.stefan = { };

  # oh-my-pi on p0's Qwen: models.yml (./omp-common.nix) resolves the key
  # through `p0-api-key`, which reads the per-user copy this installs at
  # /run/inference-api-key/stefan/token (./inference-api-key.nix).
  hyper.inferenceApiKey.users = [ "stefan" ];
}
