# cm-pi's part of ./default.nix: Home Assistant's OwnTracks integration and
# the agents' read-only location endpoint (./location_api), both declared as
# config entries that ./seed.py writes before HA starts (config = null on
# this host: HA's .storage is the only place config entries live).
#
#   owntracks     webhook id and payload key from the shared generator
#                 owntracks-secrets (./vars.nix), readable by hass only. Its MQTT side stays
#                 idle (no broker configured); the integration imports
#                 HA's mqtt component, hence paho-mqtt.
#   location_api  entity device_tracker.dave_pixel, readers = the sha256 of
#                 each agent's token (public vars of som's
#                 location-reader-<agent> generators), sources = som's
#                 yggdrasil address.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.hyper.owntracks;
  vars = config.clan.core.vars.generators;
  pv =
    machine: generator: file:
    inputs.clan-core.clanLib.getPublicValue {
      flake = config.clan.core.settings.directory;
      inherit machine generator file;
      default = "";
    };

  locationApi = pkgs.buildHomeAssistantComponent {
    owner = "hyperconfig";
    domain = "location_api";
    version = "1.0.0";
    src = ./location_api;
  };

  entries = pkgs.writeText "owntracks-config-entries.json" (
    builtins.toJSON [
      {
        entry_id = "hyperowntracks0000000000000";
        domain = "owntracks";
        title = "OwnTracks";
        data = {
          webhook_id.file = vars.owntracks-secrets.files.webhook-id.path;
          secret.file = vars.owntracks-secrets.files.encryption-key.path;
          cloudhook = false;
        };
      }
      {
        entry_id = "hyperlocationapi00000000000";
        domain = "location_api";
        title = "Location API";
        data = {
          entity_id = cfg.entityId;
          readers = lib.filterAttrs (_: d: d != "") cfg.readerHashes;
          sources = cfg.readerSources;
        };
      }
    ]
  );
in
{
  imports = [ ./vars.nix ];

  options.hyper.owntracks = {
    readerHashes = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = lib.genAttrs cfg.readers (
        r: lib.removeSuffix "\n" (pv "som" "location-reader-${r}" "sha256")
      );
      defaultText = "sha256 of each reader's token (som's public vars)";
      description = "Reader name -> sha256 (hex) of its bearer token.";
    };
    readerSources = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # som: both agents run there (infra-space's container is masqueraded
      # by the host, dave-hermes is a host user); they dial cm-pi.d, its
      # yggdrasil address, from som's.
      default = [ (lib.removeSuffix "\n" (pv "som" "yggdrasil" "address")) ];
      defaultText = "som's yggdrasil address";
      description = "Addresses/networks the location endpoint answers.";
    };
  };

  config = {
    clan.core.vars.generators.owntracks-secrets.files = {
      webhook-id.owner = "hass";
      encryption-key.owner = "hass";
      webhook-id.restartUnits = [ "home-assistant.service" ];
      encryption-key.restartUnits = [ "home-assistant.service" ];
    };

    services.home-assistant = {
      customComponents = [ locationApi ];
      # Not extraComponents = [ "owntracks" ]: that adds its whole
      # dependency closure (matter clients, openai, ...) to cm-pi's cross
      # build. Built in, it needs only what default_config lacks: paho-mqtt
      # (it imports HA's mqtt component even without a broker); pynacl
      # (payload encryption) is in cm-pi's list already.
      extraPackages = ps: [ ps.paho-mqtt ];
    };

    # Both integrations are set up by config entry only; HA reads them at
    # start, so this runs right before it (as hass, HA's own sandbox).
    systemd.services.home-assistant.serviceConfig.ExecStartPre = lib.mkAfter [
      "${pkgs.python3.interpreter} ${./seed.py} ${config.services.home-assistant.configDir} ${entries}"
    ];
  };
}
