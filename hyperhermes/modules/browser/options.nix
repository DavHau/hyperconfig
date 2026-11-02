# Options of the agents' web tools (./default.nix).
{ lib, ... }:
{
  # Per agent, with the host's browser.enable: on for every agent unless it
  # opts out. An agent that opts out gets none of it: no Camofox server,
  # port or key, no web_extract plugin, no web-access or ocr skill, no
  # `ocr` CLI, and none of the web, browser or OCR keys in its
  # config.yaml or .env. Those keys are per agent for that reason, so an
  # operator overrides them per agent (agents.<name>.settings), where they
  # win over these defaults.
  options.services.hyperhermes.agents = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.browser.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether this agent gets the host's web tools (services.hyperhermes.browser).";
        };
      }
    );
  };

  options.services.hyperhermes.browser = with lib; {
    enable = mkEnableOption "the agents' web tools (search, extract, Camofox browser, OCR client)";

    captchaSolver = {
      baseUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "http://gpu-host:8096/v1";
        description = ''
          OpenAI-compatible endpoint of the CaptchaKraken model behind the
          agents' browser_solve_captcha (the captcha plugin of their
          camofox-browser). Null: the tool answers that this browser has no
          captcha model.
        '';
      };
      model = mkOption {
        type = types.str;
        default = "CaptchaKraken/CaptchaKraken-v1.2-GGUF";
        description = ''
          Served model name. A name registered in CaptchaKraken's
          models.json also picks the prompts and pixel budget of those
          weights.
        '';
      };
    };

    ocr.baseUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "http://gpu-host:8098";
      description = ''
        Firecrawl-Parse-compatible OCR endpoint on the deployment's own
        hardware. read_file sends scanned PDFs there, and the
        agents get an `ocr` CLI and skill for images and page ranges.
        Never point this at a third-party service: documents go there
        whole. Null: read_file reports scanned pages as needing OCR.
      '';
    };
  };
}
