# The hermes agents' web tools on top of hyperhermes' core
# (services.hyperhermes.browser): a loopback SearXNG as web_search, a
# local web_extract plugin, a per-agent Camofox browser server behind
# hermes' browser_* tools (captcha solving through a CaptchaKraken model),
# OCR on our own GPU, and the web-access skill that tells the agent which
# to use when.
#
# Per agent, the Camofox server runs as the agent's uid behind a root-held
# port of core's forwards (services.hyperhermes.forwards.camofox), owner-only
# in core's firewall; its access key and profile store live in the owner's
# 0700 state dir (camofox.nix).
{
  imports = [
    ./options.nix
    ./searxng.nix
    ./web-extract.nix
    ./camofox.nix
    ./web-access-skill.nix
    ./ocr.nix
  ];
}
