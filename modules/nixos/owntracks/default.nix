/*
  OwnTracks on Dave's phone -> Home Assistant on cm-pi, and Dave's
  location for two agents (infra-space's hermes, som's dave-hermes),
  nothing more. This file: the overview, the shared options and the clan
  vars; each machine imports its role file, which imports this one.

  A report (HTTP mode: no connection kept open, one POST per fix):

    phone --https, basic auth dave--> edi https://owntracks.davhau.com/pub
          (./edi.nix: POST only, small body, rate limit, Authorization
          stripped)
          --http over yggdrasil--> cm-pi:8123/api/webhook/<id>
          (HA's OwnTracks integration, ./home-assistant.nix)

  The phone never knows the webhook id: it lives only in edi's nginx
  include and HA's config entry. The payload is encrypted with OwnTracks'
  secretbox key, so nginx's logs and buffers see ciphertext only; edi's
  root still could read the key (the setup page carries it). HA's integration would also take an unencrypted message from
  whoever knows the webhook id, so the id (256 bits) and edi's basic auth
  are the authentication; the key is confidentiality.
  bearhouse.davhau.com (../../../machines/edi/reverse-proxy.nix) proxies all
  of HA publicly: the webhook id keeps that door shut as well.

  The tracker: device_tracker.dave_pixel (user `dave`, device `pixel`,
  tracker id `dh`), its history in HA's recorder (10 days by default).

  Agents: ./location_api (a small HA component) answers GET
  /api/hyper_location with that one entity's position and, with
  ?hours=N (<= 48), its track; nothing else of HA. Each agent has its own
  random token (som's generators location-reader-<agent>, ./agents.nix);
  HA holds only their sha256 (public vars) and answers only som's
  yggdrasil address. No HA token is handed out.

  Dave's phone setup: https://stats.davhau.com/owntracks/ (Grafana's
  pocket-id sign-in, group `stats`: Dave only; ./edi.nix) shows one
  button, an owntracks:///config?inline=... link carrying the whole
  configuration (./phone-config.py: URL, user, password, key, device and
  tracker id, battery-saving monitoring), and the .otrc file as fallback.
  Both are clan var files on edi, so no secret enters the store.

  Files: ./vars.nix (the shared generator, cm-pi and edi only),
  ./home-assistant.nix + ./seed.py + ./location_api (cm-pi),
  ./edi.nix + ./phone-config.py (edi), ./agents.nix + ./skill (som),
  ./test.nix (checks.x86_64-linux.owntracks).
*/
{ lib, ... }:
{
  options.hyper.owntracks = {
    entityId = lib.mkOption {
      type = lib.types.str;
      default = "device_tracker.dave_pixel";
      description = "The phone's tracker entity (OwnTracks user `dave`, device `pixel`).";
    };
    publicHost = lib.mkOption {
      type = lib.types.str;
      default = "owntracks.davhau.com";
      description = "edi's public name the phone reports to (https://<host>/pub).";
    };
    readers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "infra"
        "dave-hermes"
      ];
      description = "Agents that may read the location (som's location-reader-<name> generators).";
    };
  };
}
