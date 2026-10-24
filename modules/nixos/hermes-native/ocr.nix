# OCR for the agents on our own GPU (cfg.ocr.baseUrl, served by
# ../ocr-server on vit):
#   - read_file: a fully scanned PDF raises anydoc's NeedsOcrError, and
#     hermes then sends the PDF through anydoc's Firecrawl Parse client.
#     file_tools.hosted_ocr_url (patches/hermes-hosted-ocr-url.patch)
#     points that client at our endpoint instead of api.firecrawl.dev,
#     without the agent's Firecrawl key. Pointing FIRECRAWL_API_URL there
#     instead would also hand hermes' Firecrawl web and browser providers
#     to an endpoint that only parses.
#   - the `ocr` CLI and its skill, for what read_file does not OCR: the
#     scanned pages of a partly scanned PDF, and document images. The
#     skill's name also answers read_file's NEEDS OCR hint ("check whether
#     an OCR skill is available").
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.services.hermes-native;

  ocrCli = pkgs.writeShellScriptBin "ocr" ''
    OCR_URL=${lib.escapeShellArg cfg.ocr.baseUrl} exec ${lib.getExe pkgs.python3} ${./ocr-cli.py} "$@"
  '';

  skill = inputs.spaces.lib.mkAgentSkill pkgs {
    name = "ocr";
    src = lib.fileset.toSource {
      root = ./ocr-skill;
      fileset = ./ocr-skill/SKILL.md;
    };
    packages = [ ocrCli ];
  };
in
{
  config = lib.mkIf (cfg.enable && cfg.ocr.baseUrl != null) {
    services.hermes-native = {
      settings.file_tools.hosted_ocr_url = cfg.ocr.baseUrl;
      settings.skills.external_dirs = [ "${skill}/share/skills" ];
      extraPackages = [ ocrCli ];
    };
  };
}
