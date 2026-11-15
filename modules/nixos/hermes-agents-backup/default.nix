/*
  Nightly off-host backup of som's hermes agents to nas, through the
  clan `dave-backup` borgbackup instance (som is a client there:
  ../../flake-parts/nixosConfigurations.nix; repo
  nas:/pool11/enc/clan-backup/som, unit borgbackup-job-nas).

  What goes in (clan.core.state folders; the job backs up their union):
  - every agent's home /home/<agent> (code, notes, results; entity
    storage keeps it small). The datasets mounted inside it (scratch,
    ~/.cache, containers, sbox state) stay out (--one-file-system plus
    patterns), except
  - /home/dave-hermes/scratch/omd2/gamedata: original game data from an
    external source, not rebuildable.
  - every agent's HERMES_HOME (memories, skills, sessions, cron, config)
    minus caches, logs, downloaded tools and the live SQLite files. The
    databases go in as consistent copies instead: before each run
    hermes-state-dump.service runs ./state-dump.py once per agent AS THAT
    AGENT (its tree, its uid: root never opens agent-written files),
    writing /var/lib/hermes-backup/<agent>/<path>.

  The clan module runs the pre-backup command as root in the job's
  ExecStartPre; it only starts the dump unit and waits for it, and a
  failed dump (a stray non-SQLite *.db, a lock held over 60 s) does NOT
  fail the job, so one agent can't stop everyone's backup: the run goes
  on with that agent's other files and hermes-state-dump-failed fails
  instead (failed-unit alert). 04:30: after the nightly bump (01:30) and
  the 02:30 / weekend 03:30 security jobs, before the users' day.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  agentCfgs = config.services.hyperhermes.agents;
  agents = lib.attrNames agentCfgs;
  hermesHome =
    a: if agentCfgs.${a}.lockedConfig then "/var/lib/hermes/${a}/home" else "/var/lib/hermes/${a}/state/.hermes";
  dumpRoot = "/var/lib/hermes-backup";
  gamedata = "/home/dave-hermes/scratch/omd2/gamedata";
  homes = map (a: "/home/${a}") agents;
  states = map hermesHome agents;

  dump = pkgs.writers.writePython3 "hermes-state-dump" { flakeIgnore = [ "E501" ]; } (
    builtins.readFile ./state-dump.py
  );
  # A command per agent, run as that agent (%a: name, %h: HERMES_HOME).
  asEach =
    cmd:
    lib.concatMapStrings (a: ''
      setpriv --reuid=${a} --regid=users --init-groups --no-new-privs -- \
        ${lib.replaceStrings [ "%a" "%h" ] [ a (lib.escapeShellArg (hermesHome a)) ] cmd}
    '') agents;
in
{
  systemd.tmpfiles.rules = [
    "d ${dumpRoot} 0755 root root - -"
  ]
  ++ map (a: "d ${dumpRoot}/${a} 0700 ${a} users - -") agents;

  # One oneshot that dumps every agent in turn, each as its own uid, and
  # one that removes the copies again after the run (they are only for
  # borg; ~1.5G on the system disk otherwise).
  systemd.services = {
    hermes-state-dump = {
      description = "Consistent copies of the hermes agents' SQLite databases for borg";
      serviceConfig = {
        Type = "oneshot";
        Nice = 19;
        IOSchedulingClass = "idle";
      };
      path = [ pkgs.util-linux ];
      script = ''
        rc=0
        ${asEach "${dump} %h ${dumpRoot}/%a/dump || rc=1"}
        if [ "$rc" != 0 ]; then
          systemctl start --no-block hermes-state-dump-failed.service
        fi
      '';
    };
    # Only a marker: failed, so the failed-unit alert names the problem
    # (the dump's journal has which file), while the backup still runs.
    hermes-state-dump-failed = {
      description = "Some hermes agent databases could not be copied for the backup (see hermes-state-dump's journal)";
      serviceConfig.Type = "oneshot";
      script = "exit 1";
    };
    hermes-state-dump-clean = {
      description = "Remove the hermes agents' database copies after the backup";
      serviceConfig.Type = "oneshot";
      path = [ pkgs.util-linux pkgs.coreutils ];
      script = asEach "rm -rf ${dumpRoot}/%a/dump ${dumpRoot}/%a/dump.new";
    };
  };

  clan.core.state.hermes-agents = {
    folders = homes ++ [ gamedata ] ++ states ++ [ dumpRoot ];
    # The borg job's ExecStartPre / ExecStopPost run them (as
    # pre-backup-hermes-agents / post-backup-hermes-agents).
    preBackupScript = "${config.systemd.package}/bin/systemctl start hermes-state-dump.service";
    postBackupScript = "${config.systemd.package}/bin/systemctl start hermes-state-dump-clean.service";
  };
  # dave.nix backs up /home on Dave's desktops; on som /home holds only
  # the per-user datasets' mountpoints (and other people's homes): the
  # agents' homes above are the backup here.
  clan.core.state.HOME.folders = lib.mkForce [ ];

  # Patterns: the first match wins, so the gamedata include beats the
  # scratch exclude.
  services.borgbackup.jobs.nas = {
    patterns = [
      "+ sh:${gamedata}"
    ]
    ++ lib.concatMap (h: [
      "! sh:${h}/scratch"
      "! sh:${h}/.cache"
      "! sh:${h}/.local/share/containers"
      "! sh:${h}/.local/state/sbox"
    ]) homes
    ++ lib.concatMap (s: [
      # live databases; their copies are under ${dumpRoot}
      "- sh:${s}/**/*.db"
      "- sh:${s}/**/*.db-wal"
      "- sh:${s}/**/*.db-shm"
      "- sh:${s}/**/*.db-journal"
      "- sh:${s}/**/*.sqlite"
      "- sh:${s}/**/*.sqlite3"
      "- sh:${s}/**/*.sock"
      "! sh:${s}/cache"
      "! sh:${s}/image_cache"
      "! sh:${s}/audio_cache"
      "! sh:${s}/browser_screenshots"
      "! sh:${s}/browser-profile"
      "! sh:${s}/sandboxes"
      "! sh:${s}/logs"
      "! sh:${s}/lsp"
      "! sh:${s}/tools"
      "! sh:${s}/profiles/*/cache"
      "! sh:${s}/profiles/*/image_cache"
      "! sh:${s}/profiles/*/audio_cache"
      "! sh:${s}/profiles/*/browser_screenshots"
      "! sh:${s}/profiles/*/logs"
    ]) states;
    # Each given path stays on its own filesystem: datasets mounted
    # inside a home are skipped even without a pattern.
    extraCreateArgs = [ "--one-file-system" ];
    startAt = lib.mkForce "*-*-* 04:30:00 Asia/Bangkok"; # som runs on UTC
  };
}
