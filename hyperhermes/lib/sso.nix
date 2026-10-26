# The login protocol between the agents' web surfaces and the identity
# provider, as plain data: which OIDC clients exist, where they call back,
# and which group each one admits. Two consumers read it, and neither may
# restate it: the sso module (../modules/sso.nix) feeds it to the local dex
# and to hermes, and a deployment with its own identity provider (e.g. a
# clan inventory declaring pocket-id clients) declares exactly these clients.
#
# accounts: agent -> login account. One account may own several agents.
# Every agent gets a confidential PKCE client hermes-<agent> that admits the
# group hermes-<agent>, and the owning account joins that group. With a
# front door (sso.frontDoor.host), its oauth2-proxy is the confidential
# PKCE client `hermes`, admitting the group `hermes`.
{ lib }:
rec {
  clientIdOf = agent: "hermes-${agent}";
  groupOf = agent: "hermes-${agent}";
  frontDoorClientId = "hermes";
  frontDoorGroup = "hermes";

  # clientId -> { name, callbackURLs, pkce, allowedGroups }
  #
  # originOf: host name -> origin of that host as the deployment exposes
  # it (the sso module passes exposure.urlOf); defaults to https on 443.
  # frontDoor: the front door's host name, or null for none.
  oidcClients =
    {
      domain,
      accounts,
      originOf ? (import ./url.nix { inherit lib; }).originOf { },
      frontDoor ? null,
    }:
    lib.mapAttrs' (
      agent: _:
      lib.nameValuePair (clientIdOf agent) {
        name = "Hermes ${agent}";
        callbackURLs = [ "${originOf "${agent}.${domain}"}/auth/callback" ];
        pkce = true;
        allowedGroups = [ (groupOf agent) ];
      }
    ) accounts
    // lib.optionalAttrs (frontDoor != null) {
      ${frontDoorClientId} = {
        name = "Hermes";
        callbackURLs = [ "${originOf frontDoor}/oauth2/callback" ];
        # oauth2-proxy sends S256
        pkce = true;
        allowedGroups = [ frontDoorGroup ];
      };
    };

  # account -> the groups oidcClients admits it through (the front door's
  # group is the deployment's to hand out: it may admit accounts that own
  # no agent)
  accountGroups =
    accounts:
    lib.foldlAttrs (
      acc: agent: account:
      acc // { ${account} = (acc.${account} or [ ]) ++ [ (groupOf agent) ]; }
    ) { } accounts;
}
