# pinpox's (github.com/pinpox) hermes agent on som: runs NATIVE
# (services.hermes-microvm users.<n>.native, spaces
# modules/nixos/hermes/native.nix) - host units hermes-agent-pinpox /
# hermes-dashboard-pinpox as the pinpox account, no microVM. Same shape as
# ./stefan-hermes.nix: brain is p0's Qwen (the common initialModel in
# ./hermes-common.nix; seeded once into the fresh state under
# /var/lib/hermes-microvm/pinpox/state-vault). No OpenRouter, no Telegram:
# driven over SSH (hermes CLI) and the web dashboard.
{
  imports = [ ./hermes-common.nix ];

  # The spaces desktop profile auto-provisions every normal user, which
  # merges with the hyper.hermes entry below. uid pinned (id ladder in
  # ./vault-ids.nix): native mode binds the dashboard backend at
  # 20000 + uid, and ./hermes-dashboard-public.nix needs that port as a
  # constant.
  users.users.pinpox = {
    isNormalUser = true;
    uid = 1104;
    description = "pinpox - hermes agent, read-only vault consumer";
    # Read-only on /vault/parquet (./vault-ids.nix).
    extraGroups = [ "vault-ro" ];
    openssh.authorizedKeys.keys = [
      # github.com/pinpox.keys (fetched 2026-09-22)
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILSJJs01RqXS6YE5Jf8LUJoJVBxFev3R18FWXJyLeYJE pinpox"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAKact4Wb6MmbpIW1rBocXP5Knrn7zJeXmIafykQe5Ke pinpox"
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFh6rVY1K340DICKUa7jVOsoZcbD8SzEUFZlXDUX1lSRC4KiRz3MTwvV6PLVIlC17yOVgfDmx+5qgRa6iowN8nI= pinpox"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAnbhSKvtaQVPAyvv+lHCx+At0Gm3yA8jmSgUxsIgN3s pinpox"
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBCdOfrnazSXp7ZmHcePXSd4leP3Qafr4fmDr3w+AxwRChSn1zzLPjV8CvD/PdMU7jQA0HS/1ItREurmZCKS/ZnQ= pinpox"
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIGzA1cg3xTlrzYrEY9CNBiWqu6axpaMBaJfHqZQvB4RHAAAABHNzaDo= pinpox"
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBCTwBH0KIRE+9SC4n7hRAGAA7Lf/+PuCHFZzZDajy9lmYrcQdvD5SgP6Q5OikUxycniI0Zse5Xeitq9qkJNg6Lw= pinpox"
    ];
  };

  hyper.hermes.users.pinpox = {
    native = true;
    openrouter = false;
  };

  # Web dashboard at https://hermes.davhau.com/pinpox/ (password login,
  # ./hermes-dashboard-public.nix):
  #   clan vars generate som --generator hermes-dashboard-pinpox
  #   clan vars get som hermes-dashboard-pinpox/password
  hyper.hermesDashboard.users.pinpox = { };

  # oh-my-pi on p0's Qwen: models.yml (./omp-common.nix) resolves the key
  # through `p0-api-key`, which reads the per-user copy this installs at
  # /run/inference-api-key/pinpox/token (./inference-api-key.nix).
  hyper.inferenceApiKey.users = [ "pinpox" ];
}
