/*
  Tool defaults that keep rebuildable downloads (module caches, package
  stores, model files) in ~/.cache, for hosts where ~/.cache is a
  non-snapshotted scratch dataset and ~ a small, backed-up one (entity
  storage). The variables are ./vars.nix, shared with the hermes agents
  and slot guests.

  - Login sessions: environment.sessionVariables, i.e. /etc/set-environment
    (shells, which expand $HOME) and pam_env (every PAM session, systemd
    user managers included).
  - Hermes agents: their units have no PAM session, so the same variables
    go to services.hyperhermes.homeEnvironment, which resolves $HOME per
    agent, when hyperhermes is imported.
  - ./storage-skill: the agent skill explaining the layout; the host wires
    it to its agents (it needs hyperhermes' mkAgentSkill).
*/
{
  config,
  lib,
  options,
  ...
}:
let
  cfg = config.hyper.toolchainCacheDirs;
in
{
  options.hyper.toolchainCacheDirs = {
    enable = lib.mkEnableOption "tool cache and download dirs under ~/.cache";
    variables = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = import ./vars.nix;
      description = "Variables to set, values with a literal `$HOME`.";
    };
  };

  config = lib.mkIf cfg.enable (
    {
      environment.sessionVariables = cfg.variables;
    }
    # The option exists only where hyperhermes' core module is imported.
    // lib.optionalAttrs (options ? services.hyperhermes.homeEnvironment) {
      services.hyperhermes.homeEnvironment = cfg.variables;
    }
  );
}
