# Clan service tests, exposed as checks.<system>.<name> via clan-core's
# test harness (container tests; vars are generated at eval time).
{ inputs, ... }:
{
  imports = [ inputs.clan-core.flakeModules.testModule ];

  perSystem = _: {
    clan.nixosTests.remote-building = {
      imports = [ ../clan/remote-building/tests/vm/default.nix ];
      clan.modules.remote-building = ../clan/remote-building;
    };
  };
}
