# The example's hyperhermes config, inside the local container
# (services.hyperhermes.localContainer.config): one agent with its own
# slot. Everything else is the local container's default: dashboards,
# published ports and the browser tools on, dex signing in the account
# `alice` (alice@hermes.localhost), secrets generated at first boot.
#
# The agent's brain is not set here: configure its provider in hermes
# itself (dashboard or CLI), or hand a key in as a runtime file, e.g.
#   services.hyperhermes.agents.alice.secretEnv.OPENROUTER_API_KEY =
#     "/var/lib/hyperhermes-local/openrouter";
{
  services.hyperhermes.agents.alice = {
    uid = 1001;
    description = "alice - local hermes agent";
    slot = {
      enable = true;
      id = 1;
    };
  };
}
