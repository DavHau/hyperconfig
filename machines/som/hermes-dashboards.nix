# Who signs in to which of som's hermes agents (./hermes-agents.nix), as
# plain data, because two evaluations need it: the clan inventory
# (modules/flake-parts/nixosConfigurations.nix) declares the pocket-id
# clients hyperhermes' lib.sso.oidcClients derives from it (one
# confidential client hermes-<agent> per entry, the front door's `hermes`,
# and the private serve ports' client hermes-serve with one callback
# pattern per agent) plus the group hermes-<agent> the account joins; som
# publishes each dashboard at https://<agent>.<domain>/ and its serve ports
# at https://<port>.<agent>.<domain>/ for that account (hyperhermes'
# dashboards and publish modules). The account also confirms its agent's
# mail allowlist requests.
#
# domain is the agents' own site, apart from davhau.com (hyperhermes'
# dashboards module says why); frontDoor is the oauth2-proxy front door on
# davhau.com.
#
# Every agent needs an entry here; som's assertions name a missing one.
{
  domain = "davhau.fyi";
  frontDoor = "hermes.davhau.com";

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
    b3x = "b3x";
    egg = "egg";
    dave-hermes = "dave";
    joe = "dave";
    momentum = "momentum";
  };
}
