# Who signs in to which of som's hermes agents (./hermes-agents.nix), as
# plain data, because two evaluations need it: the clan inventory
# (modules/flake-parts/nixosConfigurations.nix) derives one confidential
# pocket-id client hermes-<agent> per entry plus the group hermes-<agent>
# the account joins, and som publishes each dashboard at
# https://<agent>.<domain>/ for that account
# (../../modules/nixos/hermes-dashboard-public.nix, which
# asserts that the two agree). The account also owns the agent's private
# serve ports and confirms its mail allowlist requests.
#
# Every agent needs an entry here; som's assertions name a missing one.
{
  domain = "agents.davhau.com";

  # agent -> pocket-id account
  accounts = {
    stefan = "stefan";
    pinpox = "pinpox";
    adam = "adam";
    j = "j";
    willi = "willi";
    domi = "domi";
    rti = "rti";
    chris = "chris";
    egg = "egg";
    dave-hermes = "dave";
    momentum = "momentum";
  };
}
