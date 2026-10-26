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
# PKCE client `hermes`, admitting the group `hermes`. With published ports
# (the publish module), their oauth2-proxy is the confidential PKCE client
# `hermes-serve`, admitting every agent's group (the proxy then lets only
# the port's owner through).
{ lib }:
rec {
  clientIdOf = agent: "hermes-${agent}";
  groupOf = agent: "hermes-${agent}";
  frontDoorClientId = "hermes";
  frontDoorGroup = "hermes";
  publishClientId = "hermes-serve";
  publishLoginPrefix = "/.hermes-serve-login";

  # clientId -> { name, callbackURLs, pkce, allowedGroups }
  #
  # originOf: host name -> origin of that host as the deployment exposes
  # it (the sso module passes exposure.urlOf); defaults to https on 443.
  # frontDoor: the front door's host name, or null for none.
  # publish: whether to declare the published ports' client.
  # publishHosts: agent -> its private port hosts, one exact callback each
  # (the sso module passes them; dex matches callbacks exactly), or null:
  # one host-wildcard callback per agent, for an issuer that takes host
  # patterns (pocket-id) and a caller that cannot know the ports (a clan
  # inventory: they derive from uids).
  oidcClients =
    {
      domain,
      accounts,
      originOf ? (import ./url.nix { inherit lib; }).originOf { },
      frontDoor ? null,
      publish ? false,
      publishHosts ? null,
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
    }
    // lib.optionalAttrs publish {
      ${publishClientId} = {
        name = "Hermes serve ports";
        callbackURLs = lib.concatLists (
          lib.mapAttrsToList (
            agent: _:
            map (host: "${originOf host}${publishLoginPrefix}/callback") (
              if publishHosts == null then [ "*.${agent}.${domain}" ] else publishHosts.${agent} or [ ]
            )
          ) accounts
        );
        # oauth2-proxy sends S256
        pkce = true;
        allowedGroups = lib.mapAttrsToList (agent: _: groupOf agent) accounts;
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
