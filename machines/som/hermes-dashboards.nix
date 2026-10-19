# Who signs in to which of som's hermes agents (./hermes-agents.nix), as
# plain data, because two evaluations need it: the clan inventory
# (modules/flake-parts/nixosConfigurations.nix) derives one confidential
# pocket-id client hermes-<agent> per entry plus the group hermes-<agent>
# the account joins, and the private serve ports' client hermes-serve with
# one callback pattern per agent; som publishes each dashboard at
# https://<agent>.<domain>/ and its serve ports at
# https://<port>.<agent>.<domain>/ for that account
# (../../modules/nixos/hermes-dashboard-public.nix,
# ../../modules/nixos/hermes-agents-serve.nix, which assert that the two
# agree). The account also confirms its agent's mail allowlist requests.
#
# domain is the agents' own site, apart from davhau.com
# (../../modules/nixos/hermes-dashboard-public.nix says why).
#
# Every agent needs an entry here; som's assertions name a missing one.
{
  domain = "davhau.fyi";

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
