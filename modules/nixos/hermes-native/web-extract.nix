# The web_extract backend of the agents: a hermes user plugin
# (./web-extract) that fetches and extracts on this host, without a key
# or a third-party service. It runs inside each agent's own process
# tree, as the agent's uid; the extraction libraries live in their own
# interpreter, outside the sealed hermes venv.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hermes-native;
  hlib = import ./lib.nix { inherit lib; };

  python = pkgs.python3.withPackages (ps: [
    ps.curl-cffi
    ps.trafilatura
    ps.pymupdf
  ]);

  plugin = pkgs.runCommand "hermes-web-local-extract" { } ''
    cp -r ${./web-extract} $out
    chmod -R u+w $out
    substituteInPlace $out/__init__.py --replace-fail '@python@' '${python}/bin/python3'
  '';
in
{
  config = lib.mkIf cfg.enable {
    services.hermes-native.settings = {
      # User plugins load only when listed; the list concatenates with
      # an operator's entries.
      plugins.enabled = [ "web-local-extract" ];
      web.extract_backend = lib.mkDefault "local-extract";
    };

    # Hermes discovers user plugins only under $HERMES_HOME/plugins. The
    # link is renewed before every start, after agents.nix created the
    # directory.
    systemd.services = lib.mkMerge (
      lib.mapAttrsToList (user: _: {
        "hermes-agent-${user}".preStart = lib.mkAfter ''
          ln -sfn ${plugin} ${hlib.stateDir user}/.hermes/plugins/web-local-extract
        '';
      }) cfg.users
    );
  };
}
