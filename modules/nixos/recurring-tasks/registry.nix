# The fleet's recurring tasks, as data: what must keep happening, where,
# and how fresh it must stay. ./default.nix exports each task's freshness
# on its host; ../monitoring-alerts.nix alerts on a breach (./promql.nix);
# the morning brief lists the stale ones (../infra-space/decisions.nix).
#
# Per task (attribute name = the task's label):
#   host       machine whose exporter reports it (its networking.hostName)
#   unit       systemd unit whose successful runs count; null = no run SLO
#   container  the unit runs in this nspawn guest of `host` (read from the
#              host with systemctl/journalctl -M: the guest needs no exporter)
#   runSlo     max seconds since the unit's last successful run
#   result     what the task achieves, when measurable:
#                command  bash printing the unix time the current result
#                         was made; runs unprivileged on `host`, with network
#                slo      max age in seconds
#                what     one line for the brief
#   repair     skill that repairs it (step 7 of the design starts it);
#              null = a session repairs it by hand
#   owner      who looks when it is stale
#
# Hours/days below are plain arithmetic: 26 h = a daily job with 2 h slack.
let
  h = n: n * 3600;
  d = n: n * 86400;
  # main's flake.lock as GitHub serves it now (the repo is public), not a
  # local checkout that may lag.
  mainLock = "curl -fsS --max-time 60 https://raw.githubusercontent.com/DavHau/hyperconfig/main/flake.lock";
  lockAge = input: "${mainLock} | jq -er '.nodes.\"${input}\".locked.lastModified'";
  infraSpace = {
    host = "som";
    container = "infra-space";
    owner = "infra";
  };
in
{
  decisions-curate = infraSpace // {
    unit = "decisions-curate.service";
    runSlo = h 26;
  };

  decisions-brief = infraSpace // {
    unit = "decisions-brief.service";
    runSlo = h 26;
  };

  # The nightly agent run (../infra-space/nixpkgs-bump.nix) and what it is
  # for: main's nixpkgs no older than a week.
  nixpkgs-bump = infraSpace // {
    unit = "nixpkgs-bump.service";
    runSlo = h 26;
    result = {
      command = lockAge "nixpkgs";
      slo = d 7;
      what = "main's nixpkgs";
    };
    repair = "nixpkgs-bump";
  };

  # Moved by the bump (its SearXNG steps), no unit of its own yet.
  searxng-pin = infraSpace // {
    result = {
      command = lockAge "searxng";
      slo = d 14;
      what = "main's searxng pin";
    };
    repair = "nixpkgs-bump";
  };

  # Saturday's bump also builds cm-pi and roots it on som
  # (../infra-space/gcroots.nix): the rooted system's nixpkgs date (its
  # name ends in <release>.<YYYYMMDD>.<rev>) is how far cm-pi's
  # deployable build lags; a week's cadence plus the week main may lag.
  cm-pi-build = infraSpace // {
    result = {
      command = ''
        sys=$(readlink /nix/var/nix/gcroots/infra-space/cm-pi/current)
        day=$(printf '%s\n' "$sys" | sed -nE 's/.*-nixos-system-cm-pi-[0-9.]+\.([0-9]{8})\.[0-9a-f]+$/\1/p')
        test -n "$day"
        date -u -d "$day" +%s'';
      slo = d 14;
      what = "cm-pi's rooted system's nixpkgs";
    };
    repair = "nixpkgs-bump";
  };

  # som's agents to nas (../hermes-agents-backup).
  hermes-backup = {
    host = "som";
    unit = "borgbackup-job-nas.service";
    runSlo = h 26;
    owner = "infra";
  };

  # bam's daily pull into /vault/parquet (../storagebox-sync.nix).
  storagebox-sync = {
    host = "bam";
    unit = "storagebox-sync.service";
    runSlo = h 26;
    owner = "infra";
  };
}
