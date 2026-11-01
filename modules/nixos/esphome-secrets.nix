# Secrets of the ESPHome devices (locations/*/esphome, machines/cm-pi/esphome),
# one shared generator per ESPHome directory. Each file is named after the
# `!secret` key it fills, and locations/common/esphome/esphome-secrets.sh
# writes them into that directory's gitignored secrets.yaml:
#     locations/common/esphome/esphome-secrets.sh locations/casa/esphome
# The devices are flashed from the admin's laptop, so no machine needs these:
# every file is deploy = false and stays in the repo's encrypted vars only.
#
# Only amy imports this module, so the vars are reached through amy.
# Fresh values: `clan vars generate amy` runs the generators with a file
# missing. A run always rewrites every file of its generator (prompts are
# reused), and `--generator esphome-<dir>` runs it even when nothing is
# missing: a new api key, passwords and tang keys, orphaning every clevis
# binding made against the old ones.
# Existing values: `clan vars set amy esphome-<dir>/<file>` reads the value
# from stdin, verbatim (no trailing newline: printf %s "$v" | ...). Import
# every file of a generator, so generating has nothing left to fill in.
{ lib, pkgs, ... }:
let
  # The script runs after the persisted prompts are copied to $out. Every file
  # is written without a trailing newline: it is the value, nothing else.
  generator =
    {
      prompts,
      files ? { },
      runtimeInputs ? [ ],
      script ? "",
    }:
    let
      fileNames = [
        "key"
        "ota_password"
        "ap_password"
      ]
      ++ lib.attrNames prompts
      ++ lib.attrNames files;
    in
    {
      share = true;
      prompts = lib.mapAttrs (_: p: p // { persist = true; }) prompts;
      files = lib.recursiveUpdate (lib.genAttrs fileNames (_: {
        deploy = false;
      })) files;
      runtimeInputs = [ pkgs.openssl ] ++ runtimeInputs;
      script = ''
        # ESPHome's api encryption key: base64 of 32 random bytes.
        openssl rand -base64 32 | tr -d '\n' >"$out/key"
        openssl rand -hex 16 | tr -d '\n' >"$out/ota_password"
        # The fallback AP's WPA2 password: 8 characters at least.
        openssl rand -hex 16 | tr -d '\n' >"$out/ap_password"
      ''
      + script;
    };

  wifi = suffix: devices: {
    "wifi_ssid${suffix}" = {
      type = "line";
      description = "Wi-Fi network (SSID) the ${devices} join";
    };
    "wifi_password${suffix}" = {
      type = "hidden";
      description = "password of the Wi-Fi network the ${devices} join";
    };
  };
  # An SSID is broadcast anyway; public, it shows in `clan vars list`.
  publicSsids = names: lib.genAttrs names (_: { secret = false; });
in
{
  clan.core.vars.generators = {
    esphome-casa = generator {
      prompts = wifi "" "ESPHome devices at casa";
      files = publicSsids [ "wifi_ssid" ] // {
        # Tang server keys for components/tang, as tangd-keygen makes them but
        # with a P-256 exchange key (BearSSL's P-256-only backend). The device
        # signs its advertisement at build time.
        tang_exchange_key = { };
        tang_signing_key = { };
        # The advertisement tangd serves for these keys; clevis binds against
        # it offline (`clevis encrypt tang '{"url":...,"adv":"<file>"}'`).
        tang_adv.secret = false;
        # Signing key thumbprint (S256), the `thp` clevis pins.
        tang_thp.secret = false;
      };
      runtimeInputs = [
        pkgs.jose
        pkgs.gnused
      ];
      script = ''
        jose jwk gen -i '{"alg":"ECMR","crv":"P-256"}' -o "$out/tang_exchange_key"
        jose jwk gen -i '{"alg":"ES512"}' -o "$out/tang_signing_key"
        # tangd loads every *.jwk in the directory it is given; its /adv reply
        # minus the HTTP head is the advertisement.
        keys=$(mktemp -d)
        cp "$out/tang_exchange_key" "$keys/exc.jwk"
        cp "$out/tang_signing_key" "$keys/sig.jwk"
        printf 'GET /adv HTTP/1.1\r\n\r\n' | ${pkgs.tang}/libexec/tangd "$keys" |
          sed '1,/^\r$/d' >"$out/tang_adv"
        rm -r "$keys"
        jose jwk thp -i "$out/tang_signing_key" -a S256 | tr -d '\n' >"$out/tang_thp"
      '';
    };

    esphome-playa = generator {
      prompts = wifi "" "ESPHome devices at playa";
      files = publicSsids [ "wifi_ssid" ];
    };

    esphome-cm-pi = generator {
      prompts = wifi "" "aircon ESPHome devices" // wifi "_tossa" "Mitsubishi ESPHome devices in Tossa";
      files = publicSsids [
        "wifi_ssid"
        "wifi_ssid_tossa"
      ];
    };
  };
}
