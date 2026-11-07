# The systemd-run options that run a transient unit as an agent with
# exactly the agent units' hardening (core's read-only
# services.hyperhermes.hardening.serviceConfig), for the checks that probe
# it. A list value is one -p per entry, as systemd reads repeated
# settings. The caller appends its own options and the command.
{ lib }:
{ serviceConfig, user }:
let
  render = v: if lib.isBool v then lib.boolToString v else toString v;
  props = lib.concatLists (
    lib.mapAttrsToList (name: value: map (v: "${name}=${render v}") (lib.toList value)) serviceConfig
  );
in
lib.concatStringsSep " " (
  [
    "systemd-run"
    "--uid=${user}"
    "--gid=users"
    "--setenv=PATH=/run/wrappers/bin:/run/current-system/sw/bin"
  ]
  ++ map (p: "-p ${lib.escapeShellArg p}") props
)
