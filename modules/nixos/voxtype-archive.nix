# Keeps every dictation take on Dave's desktops for replay: the voxtype
# daemon (voxtype.nix in the spaces-os input) runs a patched build that
# writes the 16 kHz audio it transcribed plus a JSON sidecar (time,
# host, model, settings, initial prompt, VAD, text) for each take; a user
# path unit encodes it to FLAC (`flac --best --verify`) in the background
# and files it under ~/.local/share/voxtype-archive/YYYY/MM/ (0700/0600).
# `voxtype-archive replay <take> --config <variant.toml>` re-transcribes an
# archived take with another config, `list` and `stats` show the archive.
#
# The archive is switched on by VOXTYPE_ARCHIVE_DIR in the daemon's unit,
# not by config.toml, so a voxtype-tuner override file
# (~/.config/voxtype/config.toml, which replaces the Nix config whole)
# doesn't turn it off; the sidecar records which config file was used.
# Package and patch: pkgs/voxtype-archive/. On by default for Dave's
# desktops (./dave-desktop/default.nix); off: hyper.voxtypeArchive.enable.
# Size: 16 kHz mono 24-bit is 48 KB/s as WAV (each sample within 2^-24 of
# the float the transcriber saw, clipped to ±1); FLAC stores that losslessly
# at roughly 25-35 KB/s for speech (the low 8 bits of a mic signal are noise),
# so ~190 takes x 18 s a month (~57 min) come to ~90-120 MB/month, ~1.3
# GB/year: no retention limit. 16-bit would halve that but lose the
# precision whisper saw. Later: sync to /vault (not built).
# On amy the archive is in the ZFS snapshots and the borg backup to nas:
# deleting a take doesn't remove it from those.
# Eager-processing takes (chunks transcribed while recording) aren't
# archived; replay doesn't apply a hotkey model override (in the sidecar).
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.hyper.voxtypeArchive;
  archive = pkgs.callPackage ../../pkgs/voxtype-archive {
    voxtypePackages = inputs.spaces.inputs.voxtype.packages.${pkgs.stdenv.hostPlatform.system};
    inherit (config.spaces.voxtype) variant;
  };
  dir = "%h/.local/share/voxtype-archive";
in
{
  options.hyper.voxtypeArchive = {
    enable = lib.mkEnableOption "archiving every voxtype dictation take as FLAC + JSON sidecar in the user's ~/.local/share/voxtype-archive";
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = archive.voxtype;
      description = "The patched voxtype the daemon runs (for builds and tests).";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.voxtype.package = lib.mkForce archive.voxtype;
    environment.systemPackages = [ archive.tool ];
    # No voxtype-tuner on Dave's desktops (closure size); evaluations
    # replay archived takes instead.
    spaces.voxtype.tuner.enable = lib.mkForce false;

    systemd.user.services.voxtype = {
      # spaces-os puts its own voxtype first on the unit's PATH (the daemon
      # script execs `voxtype` by name); the patched one replaces it (its
      # unpatched build no longer links with nixpkgs' cargoSetupHook, see
      # pkgs/voxtype-archive). Otherwise spaces-os' list: `which`, then
      # the default path, which mkForce would drop.
      path = lib.mkForce (
        [
          archive.voxtype
          pkgs.which
        ]
        # systemd.defaultPath is new in nixpkgs (2026-11); before it, the
        # same list was built into every unit's path.
        ++ config.systemd.defaultPath or [
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
          pkgs.gnused
          config.systemd.package
        ]
      );
      environment.VOXTYPE_ARCHIVE_DIR = dir;
    };

    systemd.user.paths.voxtype-archive = {
      description = "Encode new dictation takes to FLAC";
      wantedBy = [ "default.target" ];
      pathConfig = {
        DirectoryNotEmpty = "${dir}/incoming";
        MakeDirectory = true;
        DirectoryMode = "0700";
      };
    };
    systemd.user.services.voxtype-archive = {
      description = "Encode new dictation takes to FLAC";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe archive.tool} ingest";
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };
  };
}
