# The login protocol between the agents' dashboards and the identity
# provider, as plain data: which OIDC clients exist, where they call back,
# and which group each one admits. Two consumers read it, and neither may
# restate it: the sso module (../modules/sso.nix) feeds it to the local dex
# and to hermes, and a deployment with its own identity provider (e.g. a
# clan inventory declaring pocket-id clients) declares exactly these clients.
#
# accounts: agent -> login account. One account may own several agents.
# Every agent gets a confidential PKCE client hermes-<agent> that admits the
# group hermes-<agent>, and the owning account joins that group.
{ lib }:
rec {
  clientIdOf = agent: "hermes-${agent}";
  groupOf = agent: "hermes-${agent}";

  # clientId -> { name, callbackURLs, pkce, allowedGroups }
  #
  # originOf: host name -> origin of that host as the deployment exposes
  # it (the sso module passes exposure.urlOf); defaults to https on 443.
  oidcClients =
    {
      domain,
      accounts,
      originOf ? (import ./url.nix { inherit lib; }).originOf { },
    }:
    lib.mapAttrs' (
      agent: _:
      lib.nameValuePair (clientIdOf agent) {
        name = "Hermes ${agent}";
        callbackURLs = [ "${originOf "${agent}.${domain}"}/auth/callback" ];
        pkce = true;
        allowedGroups = [ (groupOf agent) ];
      }
    ) accounts;

  # account -> the groups oidcClients admits it through
  accountGroups =
    accounts:
    lib.foldlAttrs (
      acc: agent: account:
      acc // { ${account} = (acc.${account} or [ ]) ++ [ (groupOf agent) ]; }
    ) { } accounts;
}
