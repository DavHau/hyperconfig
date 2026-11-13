# Bluetooth speaker output for speech-tts (./tts.py --bt-*): the spoken
# replies play on a paired A2DP sink (Dave's soundbar) attached to this
# host, and HA/the satellite get a silent wav of the same length (so the
# satellite stays "responding" and doesn't hear itself).
#
# Audio stack: bluez-alsa (system bluealsa daemon, A2DP source, SBC only;
# no PipeWire on this headless box). tts.py pipes PCM into aplay on the
# bluealsa ALSA plugin, small buffer, at the transport's own rate (soxr in
# python, no ALSA resampling). speech-bt-link keeps the ACL link up: it
# reconnects the trusted sink whenever it's gone (soundbar off, out of
# range), every `linkInterval` s. bluealsa --keep-alive holds the A2DP
# transport for `keepAlive` s after a reply so back-to-back replies skip
# the AVDTP start.
#
# Output selection: ${state}/tts-output ("soundbar" or "voice-pe"), set
# via tts.py's PUT /output (GET /output shows sink state); the default
# when the file is missing is "soundbar". If the sink isn't connected the
# reply goes to the satellite as before.
{ config, lib, pkgs, ... }:
let
  cfg = config.hyper.wyomingLocalSpeech;
  bt = cfg.btSpeaker;
  balsa = pkgs.bluez-alsa;
  alsaConf = pkgs.writeText "speech-bt-alsa.conf" ''
    <${pkgs.alsa-lib}/share/alsa/alsa.conf>
    <${balsa}/etc/alsa/conf.d/20-bluealsa.conf>
  '';
in
{
  options.hyper.wyomingLocalSpeech.btSpeaker = {
    mac = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "MAC of a paired+trusted A2DP sink for spoken replies (null = off).";
    };
    keepAlive = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "bluealsa --keep-alive: seconds the A2DP transport stays acquired after a reply.";
    };
    linkInterval = lib.mkOption { type = lib.types.int; default = 10; };
  };

  config = lib.mkIf (cfg.enable && bt.mac != null) {
    users.users.bluealsa = { isSystemUser = true; group = "bluealsa"; extraGroups = [ "audio" ]; };
    users.groups.bluealsa = { };
    # dbus policy: bluealsa owns org.bluealsa, group audio may talk to it.
    services.dbus.packages = [ balsa ];
    users.users.speech.extraGroups = [ "audio" ];

    systemd.services.bluealsa = {
      description = "BlueALSA (A2DP source for speech-tts)";
      after = [ "bluetooth.service" "dbus.service" ];
      requires = [ "bluetooth.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "dbus";
        BusName = "org.bluealsa";
        User = "bluealsa";
        ExecStart = "${balsa}/bin/bluealsa -S -p a2dp-source -c SBC --keep-alive=${toString bt.keepAlive}";
        Restart = "always";
        RestartSec = 3;
        AmbientCapabilities = [ "CAP_NET_RAW" ];
        CapabilityBoundingSet = [ "CAP_NET_RAW" ];
        StateDirectory = "bluealsa";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [ "AF_UNIX" "AF_BLUETOOTH" ];
      };
    };

    # Keep the soundbar connected: (re)connect whenever it's not.
    systemd.services.speech-bt-link = {
      description = "Keep the speech Bluetooth speaker ${bt.mac} connected";
      after = [ "bluealsa.service" ];
      bindsTo = [ "bluealsa.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.bluez pkgs.gnugrep pkgs.coreutils ];
      script = ''
        was=""
        while :; do
          if bluetoothctl info ${bt.mac} | grep -q 'Connected: yes'; then
            [ "$was" = yes ] || echo "connected"
            was=yes
          else
            [ "$was" = no ] || echo "not connected, retrying every ${toString bt.linkInterval}s"
            was=no
            timeout 15 bluetoothctl connect ${bt.mac} >/dev/null 2>&1 && echo "connected"
          fi
          sleep ${toString bt.linkInterval}
        done
      '';
      serviceConfig = { Restart = "always"; RestartSec = 5; };
    };

    systemd.services.speech-tts = {
      wants = [ "bluealsa.service" ];
      after = [ "bluealsa.service" ];
      environment = {
        ALSA_CONFIG_PATH = "${alsaConf}";
        ALSA_PLUGIN_DIR = "${balsa}/lib/alsa-lib";
      };
      serviceConfig.SupplementaryGroups = [ "audio" ];
    };
    hyper.wyomingLocalSpeech.ttsExtraArgs = [
      "--bt-mac" bt.mac
      "--bt-aplay" "${pkgs.alsa-utils}/bin/aplay"
      "--bt-busctl" "${pkgs.systemd}/bin/busctl"
      "--output-file" "/var/lib/speech/tts-output"
    ];
  };
}
