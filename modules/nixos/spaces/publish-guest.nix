/*
  A space's published web apps, the guest's side (./publish.nix has the
  host's, ./default.nix wires both from hyper.spaces.<name>.publish).

  Whatever the space's user listens on in the port window
  (`space.publish.from` .. `to`, 8000-8099 by default) on 0.0.0.0 or the
  guest's veth address (`space.publish.address`) is
  https://<port>.<space>.<domain>/ for the space's owners, nothing to
  register. The host's nginx dials <address>:<port>; nothing else reaches
  the window (the host's output gate, ./host.nix, admits nginx's uid to
  the window only, and the guest admits only the host's veth address,
  ./guest-base.nix).

    - `space-publish <port>`: for an app that binds 127.0.0.1 only and
      cannot be told otherwise, forwards <address>:<port> to
      127.0.0.1:<port> (socat, foreground, until Ctrl-C) and prints the
      URL. A different address than the app's, so both bind the same
      port. `space-publish` alone prints the scheme and what listens in
      the window.
    - SPACE_PUBLIC_URL_TEMPLATE (`https://{port}.<space>.<domain>`) and
      SPACE_PUBLISH_PORTS (`8000-8099`) in every session, the scheme in
      the motd, and the space-publish skill for afk (./publish-skill).
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.space.publish;
  template = "https://{port}.${config.space.name}.${cfg.domain}";
  helper = pkgs.writeShellApplication {
    name = "space-publish";
    runtimeInputs = [
      pkgs.socat
      pkgs.iproute2
      pkgs.gnugrep
      pkgs.gawk
    ];
    text = ''
      from=${toString cfg.from} to=${toString cfg.to}
      url() { echo "https://$1.${config.space.name}.${cfg.domain}/"; }
      if [ $# -eq 0 ] || [ "$1" = -h ] || [ "$1" = --help ]; then
        echo "Listen on 0.0.0.0:<port> (or ${cfg.address}:<port>), port $from-$to, and open"
        echo "  $(url '<port>')"
        echo "(pocket-id login; only ${lib.concatStringsSep ", " cfg.accounts} get through)."
        echo "For an app bound to 127.0.0.1 only: space-publish <port> (forwards until Ctrl-C)."
        echo
        echo "Listening in the window now:"
        ss -Hltn "sport >= :$from and sport <= :$to" | grep . || echo "  nothing"
        exit 0
      fi
      port=$1
      if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt "$from" ] || [ "$port" -gt "$to" ]; then
        echo "space-publish: port must be $from-$to (got $port)" >&2
        exit 2
      fi
      # the local address column only (the peer's is 0.0.0.0:* always)
      if ss -Hltn "sport = :$port" | awk '{ print $4 }' | grep -qE '^(0\.0\.0\.0|\*|\[::\]|${lib.escapeRegex cfg.address}):'; then
        echo "Already reachable: something listens on all addresses on $port."
        echo "  $(url "$port")"
        exit 0
      fi
      echo "Forwarding ${cfg.address}:$port -> 127.0.0.1:$port until Ctrl-C:"
      echo "  $(url "$port")"
      exec socat TCP-LISTEN:"$port",bind=${cfg.address},reuseaddr,fork TCP:127.0.0.1:"$port"
    '';
  };
in
{
  options.space.publish = {
    enable = lib.mkEnableOption "the space's published port window";
    from = lib.mkOption {
      type = lib.types.port;
      description = "First port of the window.";
    };
    to = lib.mkOption {
      type = lib.types.port;
      description = "Last port of the window.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      description = "Apps are https://<port>.<space>.<domain>/.";
    };
    address = lib.mkOption {
      type = lib.types.str;
      description = "The guest's veth address, which the host's nginx dials.";
    };
    accounts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "pocket-id accounts let through (for the help text).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ helper ];
    environment.variables = {
      SPACE_PUBLIC_URL_TEMPLATE = template;
      SPACE_PUBLISH_PORTS = "${toString cfg.from}-${toString cfg.to}";
    };
    users.motd = ''
      Web apps: listen on 0.0.0.0:<${toString cfg.from}-${toString cfg.to}>, open ${template}
      (127.0.0.1-only app: `space-publish <port>`).
    '';
    hyper.afk.extraSkills.space-publish = ./publish-skill;
  };
}
