# The web_extract backend of the agents: a hermes user plugin
# (./web-extract) that fetches and extracts on this host, without a key
# or a third-party service. It runs inside each agent's own process
# tree, as the agent's uid; the extraction libraries live in their own
# interpreter, outside the sealed hermes venv. A page that the plain
# fetch finds blocked or JavaScript-only is rendered once more in a
# headless Camoufox, the build the camoufox library pins.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes;
  hlib = import ../../lib/core.nix { inherit lib; };

  camoufox = pkgs.callPackage ../../pkgs/camoufox/browser.nix { };
  python = pkgs.python3.withPackages (ps: [
    ps.curl-cffi
    ps.trafilatura
    ps.pymupdf
    (ps.callPackage ../../pkgs/camoufox/python.nix { })
  ]);

  # Only the plugin's own files, so stray files (__pycache__) never change it.
  src = lib.fileset.toSource {
    root = ./web-extract;
    fileset = lib.fileset.unions [
      ./web-extract/plugin.yaml
      ./web-extract/__init__.py
      ./web-extract/fetch.py
    ];
  };
  plugin = pkgs.runCommand "hermes-web-local-extract" { } ''
    cp -r ${src} $out
    chmod -R u+w $out
    substituteInPlace $out/__init__.py --replace-fail '@python@' '${python}/bin/python3'
    substituteInPlace $out/fetch.py --replace-fail '@camoufox@' '${camoufox}/lib/camoufox/camoufox'
  '';
  browserAgents = lib.filterAttrs (_: a: a.browser.enable) cfg.agents;
in
{
  # Per agent (./options.nix says why not host-wide).
  options.services.hyperhermes.agents = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, ... }:
        {
          config.settings = lib.mkIf (cfg.browser.enable && config.browser.enable) {
            # User plugins load only when listed; the list is a union with
            # the host's and the operator's entries (core's settingsFor).
            plugins.enabled = [ "web-local-extract" ];
            web.extract_backend = lib.mkDefault "local-extract";
            # On failure hermes would retry through free third-party services
            # (Exa, Parallel, Firecrawl), sending the agent's URLs and queries
            # off-host. SearXNG and the local extractor cover both paths.
            web.keyless_rescue = lib.mkDefault false;
          };
        }
      )
    );
  };

  config = lib.mkIf cfg.browser.enable {
    # Hermes discovers user plugins only under $HERMES_HOME/plugins. The
    # link is renewed before every start, after core's preStart created
    # the directory.
    systemd.services = lib.mkMerge (
      lib.mapAttrsToList (user: _: {
        "hermes-agent-${user}".preStart = lib.mkAfter ''
          ln -sfn ${plugin} ${hlib.stateDir user}/.hermes/plugins/web-local-extract
        '';
      }) browserAgents
    );
  };
}
