# Who signs in to the infra-space dashboard (./dashboard.nix, on som), as
# plain data for the two evaluations that need it: the clan inventory
# declares the pocket-id client and group hyperhermes' lib.sso derives from
# it (client and group hermes-<name>, callback
# https://<name>.<som's agent domain>/auth/callback; the account joins the
# group), som publishes the dashboard at that name
# (modules/flake-parts/nixosConfigurations.nix,
# machines/som/configuration.nix). The same convention as som's agent
# dashboards (machines/som/hermes-dashboards.nix), kept apart from them:
# this agent runs in the container, not on som, and has no serve ports.
{
  name = "infra-space";
  account = "dave";
}
