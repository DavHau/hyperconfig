# The agents' `web-access` skill (./web-access-skill): which of this
# host's web tools to use in which order (web_search on SearXNG,
# web_extract from web-extract.nix, the Camofox browser_* tools from
# camofox.nix) and how to tell a missing domain or a rate limit from a
# bot wall. Without it the agent reached for curl with a spoofed
# User-Agent, which Cloudflare blocks on the TLS fingerprint, and
# followed hermes' bundled blocked-page-recovery, whose ladder ranks the
# real browser last. It describes tools from more than one file here, so
# it lives beside them rather than inside either.
#
# Host-scoped: it names tools only this module sets up, so it is its own
# skills root (a second entry in skills.external_dirs), not part of the
# host's other skill roots. Its name must stay unique across every root, hermes'
# bundled skills included, or skill_view refuses both copies as
# ambiguous.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.services.hyperhermes;

  skill = inputs.hyperhermes.lib.mkAgentSkill pkgs {
    name = "web-access";
    src = lib.fileset.toSource {
      root = ./web-access-skill;
      fileset = ./web-access-skill/SKILL.md;
    };
  };
in
{
  config = lib.mkIf cfg.browser.enable {
    services.hyperhermes.skillDirs = [ "${skill}/share/skills" ];
  };
}
