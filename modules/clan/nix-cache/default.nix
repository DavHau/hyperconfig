# Machines substitute from each other before building.
#
# roles.server: harmonia serves this machine's /nix/store on
#   <machine>.d:5000 (yggdrasil only), signing on the fly with a
#   per-machine key (clan var nix-cache-<instance>, public half readable by
#   every client).
# roles.client: ncro, a local routing proxy, is the daemon's first
#   substituter. It races the servers and this machine's own public caches
#   (nix.settings.substituters, left as the modules define it) and keeps
#   probing them, so a sleeping or unreachable server drops out of the race
#   instead of stalling each lookup. The public caches stay listed directly
#   behind ncro, so a stopped ncro costs one refused local connection.
{ clanLib, ... }:
{
  _class = "clan.service";
  manifest.name = "hyperconfig/nix-cache";
  manifest.description = "Substitute store paths from other clan machines, tolerant of machines being down";
  manifest.categories = [ "System" ];

  roles.server = {
    description = "Serves this machine's nix store to the clients, signed with its own key.";

    perInstance =
      { instanceName, ... }:
      {
        nixosModule =
          {
            config,
            pkgs,
            ...
          }:
          let
            machineName = config.clan.core.settings.machine.name;
          in
          {
            clan.core.vars.generators."nix-cache-${instanceName}" = {
              files.sign-key = { };
              files.pub-key.secret = false;
              runtimeInputs = [ pkgs.nix ];
              script = ''
                nix-store --generate-binary-cache-key ${machineName}.d-1 \
                  "$out"/sign-key "$out"/pub-key
              '';
            };

            services.harmonia.cache = {
              enable = true;
              signKeyPaths = [ config.clan.core.vars.generators."nix-cache-${instanceName}".files.sign-key.path ];
              settings.bind = "[::]:5000";
            };
            # Reachable over yggdrasil (the <machine>.d names) only.
            networking.firewall.interfaces.ygg.allowedTCPPorts = [ 5000 ];
          };
      };
  };

  roles.client = {
    description = "Routes the daemon's substitution through a local ncro that races servers and public caches.";

    interface =
      { lib, ... }:
      {
        options = {
          port = lib.mkOption {
            type = lib.types.port;
            default = 37515;
            description = "Loopback port of the local ncro.";
          };
        };
      };

    perInstance =
      {
        instanceName,
        roles,
        settings,
        ...
      }:
      {
        nixosModule =
          {
            config,
            lib,
            inputs,
            ...
          }:
          let
            machineName = config.clan.core.settings.machine.name;
            servers = lib.filter (m: m != machineName) (lib.attrNames (roles.server.machines or { }));
            # Null until the server's vars exist, so a fresh checkout evaluates.
            keyOf =
              machine:
              clanLib.getPublicValue {
                flake = config.clan.core.settings.directory;
                generator = "nix-cache-${instanceName}";
                file = "pub-key";
                inherit machine;
                default = null;
              };
            peers = lib.filter (p: p.key != null) (
              map (m: {
                url = "http://${m}.d:5000";
                key = keyOf m;
              }) servers
            );
            # "https://cache.nixos.org/?priority=40" -> "https://cache.nixos.org"
            bareUrl = url: lib.removeSuffix "/" (lib.head (lib.splitString "?" url));
            local = "http://127.0.0.1:${toString settings.port}";
            publicCaches = lib.remove local (
              lib.unique (map bareUrl config.nix.settings.substituters)
            );
          in
          {
            imports = [ inputs.ncro.nixosModules.ncro ];

            services.ncro = {
              enable = true;
              # No socket activation: with it, systemd keeps accepting on the
              # port while ncro fails, and nix hangs on each request instead
              # of getting a refused connection and moving to the next
              # substituter.
              socketActivation = false;
              # Nix verifies signatures itself against trusted-public-keys.
              addUpstreamPublicKeys = false;
              settings = {
                server.listen = "127.0.0.1:${toString settings.port}";
                upstreams =
                  map (p: {
                    inherit (p) url;
                    priority = 5;
                    public_key = lib.trim p.key;
                    # A live peer answers within milliseconds. Without a
                    # short timeout a down peer holds every lookup for ncro's
                    # 5 s race timeout; after it fails it sits out the
                    # cooldown below.
                    narinfo_timeout = "1s";
                  }) peers
                  ++ map (url: {
                    inherit url;
                    priority = 20;
                  }) publicCaches;
                cache.mass_query = {
                  upstream_cooldown = "60s";
                  # ncro holds each upstream to this many narinfo requests at
                  # once and queues the rest (default 8). A build of many
                  # uncached derivations makes nix ask for hundreds of
                  # paths that are in no cache; each miss waits ~0.3 s for
                  # cache.nixos.org's 404, so with 8 slots 32 nix
                  # connections saw ~1.1 s per lookup and the tail ran into
                  # nix's connect-timeout (see below). cache.nixos.org is a
                  # CDN and the peers answer within milliseconds; nix
                  # itself would open up to http-connections to them.
                  per_upstream_max_inflight = 64;
                  # Lookups racing at once across all upstreams (default 64);
                  # above what one nix daemon opens, so it never queues them.
                  max_concurrent_races = 256;
                };
                # Outside health tracking and cooldown: a last resort that
                # still answers if the routing itself misbehaves. ncro needs
                # the URL spelled out in a config file.
                fallback_cache = {
                  enabled = true;
                  url = "https://cache.nixos.org";
                };
                logging.format = "text";
              };
            };

            nix.settings.trusted-public-keys = map (p: lib.trim p.key) peers;

            # ncro advertises priority 30, ahead of the public caches (40+),
            # which stay listed: a stopped ncro is one refused local
            # connection, then nix asks them as before.
            nix.settings.substituters = lib.mkBefore [ local ];
            # A path no substituter can deliver gets built.
            nix.settings.fallback = true;
            # Back to nix's own default (clan's recommended defaults set 5).
            # libcurl counts the time a request waits in nix's queue for one
            # of the http-connections against connect-timeout, and nix
            # queues up to 5x that many narinfo lookups at once. In a burst
            # of misses (~0.3 s each) a short limit fails healthy lookups
            # with "Operation timed out ... 0 bytes received". Slow or dead
            # peers are ncro's job (narinfo_timeout + cooldown); nix itself
            # only talks to the local ncro and the public caches.
            nix.settings.connect-timeout = lib.mkOverride 90 15;
          };
      };
  };
}
