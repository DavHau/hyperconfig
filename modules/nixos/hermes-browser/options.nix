# Options of the agents' web tools (./default.nix).
{ lib, ... }:
{
  options.services.hyperhermes.browser = with lib; {
    enable = mkEnableOption "the agents' web tools (search, extract, Camofox browser, OCR client)";

    captchaSolver = {
      baseUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "http://vit.d:8096/v1";
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
      example = "http://vit.d:8098";
      description = ''
        Firecrawl-Parse-compatible OCR endpoint on our own hardware
        (../ocr-server). read_file sends scanned PDFs there, and the
        agents get an `ocr` CLI and skill for images and page ranges.
        Never point this at a third-party service: documents go there
        whole. Null: read_file reports scanned pages as needing OCR.
      '';
    };
  };
}
