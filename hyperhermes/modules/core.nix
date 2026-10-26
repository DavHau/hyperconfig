# The agent registry: one hermes agent per entry, each a login account of
# its own on this host. Feature modules extend the per-agent submodule by
# redeclaring `agents` with options of their own.
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.hyperhermes;
in
{
  options.services.hyperhermes.agents = lib.mkOption {
    default = { };
    description = "Hermes agents on this host, by account name.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.uid = lib.mkOption {
          type = lib.types.int;
          description = "The agent account's uid; ports and firewall rules derive from it.";
        };
      }
    );
  };

  config = lib.mkIf (cfg.agents != { }) {
    assertions = [
      {
        assertion = lib.allUnique (lib.mapAttrsToList (_: a: a.uid) cfg.agents);
        message = "services.hyperhermes.agents: two agents share a uid.";
      }
    ];

    users.users = lib.mapAttrs (_: a: {
      isNormalUser = true;
      inherit (a) uid;
    }) cfg.agents;
  };
}
