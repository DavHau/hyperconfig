# Hermes agents as clients of an HTTP API served from a container slot
# (hyperhermes' container-slots): per instance `hyper.slotApiClients.<name>`,
# the slot's own CLI on the agents' PATH (sandboxed), a skill, and, with
# `api.enable`, one bearer token per agent.
#
# The CLI: the slot publishes its binary to the host (container-slots
# `publishBins`, /run/container-slot-bins/<slot>/<bin>). It is the slot's
# code, so the agents run it through a wrapper that
#   - passes only the listed subcommands and refuses flags that would put
#     the token on argv (som has no hidepid: argv is public) or write files
#     (`refusedFlags`; advisory: the sandbox is the boundary, the refusal
#     tells the agent the right form),
#   - copies input files (`cli.inputFlags`) into a private directory the
#     sandbox may read,
#   - runs it under Landlock (landrun): read-only /nix/store and
#     `cli.readPaths`, no file writes, TCP connect only to the API's port,
#     no signals to or abstract sockets of other processes, an environment
#     holding only the API variables; then ./slot-cli-exec.c: refuses a
#     kernel below Landlock ABI 6, closes inherited fds, and a seccomp
#     filter denies what Landlock <= ABI 8 leaves open: chmod/chown/xattr/
#     timestamp changes (EPERM) and every socket but plain TCP over
#     IPv4/IPv6 (EACCES; no MPTCP, SCTP, UDP, ICMP, netlink or unix
#     sockets; an unnamed socketpair stays). landrun runs best-effort for
#     the bits above ABI 6 (som's kernel has ABI 7).
# The wrapper is not what protects the API: the agent holds its token and
# can call the API with curl. The service's own scopes do (below).
#
# The API (`api.enable`, default off): per agent a generator
# <name>-api-<agent> with a random `token` (secret, root-only: the agent
# unit's LoadCredential reads it into the agent's .env through hyperhermes'
# secretEnv as <PREFIX>_API_TOKEN; generating it restarts that agent once)
# and its `sha256` (public). The hashes go into the slot as one managed
# file (container-slots `managedFiles`, `api.clientsFile`), a line
# `<agent> <sha256 hex>` each; nothing is restarted, the service re-reads
# the file. <PREFIX>_API_URL is the slot's address and port. Agents with
# `lan = false` (hyper.ztEuLanGuard.noLan) get exactly that address and
# port allowed.
#
# Switch `api.enable` on only once the service takes the file with a
# read-only scope for its entries (the instance's file says which service
# change that is): until then the tokens open nothing, and a service that
# accepted them with full rights would hand every agent its write
# endpoints.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.hyper.slotApiClients;
  slots = config.services.container-slots;
  vars = config.clan.core.vars.generators;
  genOf = name: agent: "${name}-api-${agent}";
  addressOf = i: "${slots.ipv6Prefix}::5107:${lib.toLower (lib.toHexString slots.slots.${i.slot}.id)}";
  urlOf = i: "http://[${addressOf i}]:${toString i.port}";

  # The last step before the slot's binary (./slot-cli-exec.c): Landlock
  # ABI check, fds closed, the seccomp filter.
  slotCliExec = pkgs.runCommandCC "slot-cli-exec" { buildInputs = [ pkgs.libseccomp ]; } ''
    mkdir -p $out/bin
    $CC -O2 -Wall -Werror ${./slot-cli-exec.c} -o $out/bin/slot-cli-exec -lseccomp
  '';

  wrapperOf =
    name: i:
    let
      bin = "/run/container-slot-bins/${i.slot}/${i.cli.bin}";
    in
    pkgs.writeShellScriptBin i.cli.bin ''
      set -euo pipefail
      bin=${lib.escapeShellArg bin}
      if [ ! -x "$bin" ]; then
        echo "${i.cli.bin}: the client is not available right now (slot ${i.slot} not deployed or stopped); retry later" >&2
        exit 1
      fi
      case "''${1:-}" in
        ${lib.concatMapStringsSep " | " lib.escapeShellArg (
          i.cli.subcommands
          ++ [
            "help"
            "-h"
            "--help"
            "-V"
            "--version"
          ]
        )}) ;;
        *)
          echo "${i.cli.bin}: only these subcommands are available here: ${lib.concatStringsSep ", " i.cli.subcommands}" >&2
          exit 2
          ;;
      esac
      for a in "$@"; do
        case "$a" in
          ${lib.concatMapStringsSep " | " (f: "${lib.escapeShellArg f} | ${lib.escapeShellArg f}=*") i.cli.refusedFlags})
            echo "${i.cli.bin}: $a is refused here: the token comes from the environment (${i.envPrefix}_API_TOKEN), output goes to stdout (redirect it)" >&2
            exit 2
            ;;
        esac
      done
      # Input files (inputFlags) are copied into a private directory the
      # sandbox may read; the sandbox reads nothing of the caller's own.
      args=()
      extra=()
      ${lib.optionalString (i.cli.inputFlags != [ ]) ''
        tmp=
        trap '[ -z "$tmp" ] || rm -rf -- "$tmp"' EXIT
        # Sets $copied to the private copy of file $1.
        copyin() {
          if [ -z "$tmp" ]; then
            tmp=$(mktemp -d)
            extra=(--ro "$tmp")
          fi
          copied="$tmp/in''${#args[@]}"
          cat -- "$1" >"$copied" || { echo "${i.cli.bin}: cannot read $1" >&2; exit 2; }
        }
      ''}
      while [ $# -gt 0 ]; do
        case "$1" in
          ${lib.concatMapStrings (f: ''
            ${lib.escapeShellArg f})
              [ $# -ge 2 ] || { echo "${i.cli.bin}: $1 needs a file" >&2; exit 2; }
              copyin "$2"; args+=("$1" "$copied"); shift 2; continue ;;
            ${lib.escapeShellArg f}=*)
              copyin "''${1#*=}"; args+=("${f}=$copied"); shift; continue ;;
          '') i.cli.inputFlags}
        esac
        args+=("$1")
        shift
      done
      ${lib.optionalString (i.cli.urlEnv != null) ''
        if [ -n "''${${i.envPrefix}_API_URL:-}" ]; then
          export ${i.cli.urlEnv}="''${${i.envPrefix}_API_URL}"
        fi
      ''}
      envs=()
      for v in ${lib.escapeShellArgs ([ "${i.envPrefix}_API_TOKEN" ] ++ lib.optional (i.cli.urlEnv != null) i.cli.urlEnv ++ [ "RUST_LOG" "TZ" ])}; do
        if [ -n "''${!v:-}" ]; then envs+=(--env "$v"); fi
      done
      ${if i.cli.inputFlags != [ ] then "" else "exec "}${pkgs.landrun}/bin/landrun --best-effort \
        --rox /nix/store \
        ${lib.concatMapStringsSep " " (p: "--ro ${lib.escapeShellArg p}") i.cli.readPaths} \
        --ignore-missing --ro /etc/ssl --ro /etc/localtime --ro /etc/zoneinfo \
        --connect-tcp ${toString i.port} \
        "''${extra[@]}" "''${envs[@]}" \
        -- ${slotCliExec}/bin/slot-cli-exec "$bin" "''${args[@]}"
    '';

  skillOf =
    name: i:
    inputs.hyperhermes.lib.mkAgentSkill pkgs {
      name = i.skill.name;
      src = pkgs.writeTextDir "SKILL.md" (
        lib.replaceStrings
          [ "@API@" ]
          [ (if i.api.enable then i.skill.apiOn else i.skill.apiOff) ]
          (builtins.readFile i.skill.file)
      );
    };

  instanceOptions = {
    options = {
      slot = lib.mkOption {
        type = lib.types.str;
        description = "The container slot serving the API.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        description = "TCP port of the API on the slot's public v6 address.";
      };
      agents = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Hermes agents that get the CLI, the skill and (with api.enable) a token.";
      };
      envPrefix = lib.mkOption {
        type = lib.types.strMatching "[A-Z][A-Z0-9_]*";
        description = "The agents' env: <prefix>_API_URL and <prefix>_API_TOKEN.";
      };
      api = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Per-agent tokens: generators, the agents' env, the hash file in
            the slot, the LAN-guard exception. Only once the service gives
            the file's entries a read-only scope (see the module header).
          '';
        };
        clientsFile = lib.mkOption {
          type = lib.types.str;
          default = "api-clients";
          description = "Name of the hash file in the slot (container-slots managedFiles).";
        };
      };
      cli = {
        bin = lib.mkOption {
          type = lib.types.strMatching "[A-Za-z0-9_][A-Za-z0-9_.+-]*";
          description = "The slot's client binary (published with container-slots publishBins).";
        };
        subcommands = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          description = "Subcommands the wrapper passes; everything else is refused.";
        };
        refusedFlags = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Flags refused (also as --flag=value): ones carrying a secret on argv or writing files.";
        };
        readPaths = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Paths the sandboxed CLI may read besides /nix/store.";
        };
        inputFlags = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Flags naming an input file: the wrapper copies it into a private directory the sandbox may read.";
        };
        urlEnv = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Env var the CLI reads its service URL from; the wrapper sets it from <prefix>_API_URL.";
        };
      };
      skill = {
        name = lib.mkOption { type = lib.types.str; };
        file = lib.mkOption {
          type = lib.types.path;
          description = "SKILL.md; `@API@` is replaced by apiOn or apiOff.";
        };
        apiOn = lib.mkOption { type = lib.types.lines; };
        apiOff = lib.mkOption { type = lib.types.lines; };
      };
    };
  };

  enabled = lib.filterAttrs (_: i: i.agents != [ ]) cfg;
  withApi = lib.filterAttrs (_: i: i.api.enable) enabled;
  noLanUsers = config.hyper.ztEuLanGuard.noLan.users;
in
{
  options.hyper.slotApiClients = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule instanceOptions);
    default = { };
    description = "Hermes agents as clients of a container slot's HTTP API (see the module header).";
  };

  config = lib.mkIf (enabled != { }) {
    assertions = lib.concatLists (
      lib.mapAttrsToList (
        name: i:
        map (a: {
          assertion = config.services.hyperhermes.agents ? ${a};
          message = "hyper.slotApiClients.${name}.agents: ${a} is not a hermes agent";
        }) i.agents
        ++ [
          {
            assertion = slots.slots ? ${i.slot};
            message = "hyper.slotApiClients.${name}.slot: no container slot ${i.slot}";
          }
        ]
      ) enabled
    );

    services.container-slots.slots = lib.mkMerge (
      lib.mapAttrsToList (name: i: {
        ${i.slot} = {
          publishBins = [ i.cli.bin ];
          # Kept (empty) with the API off, so switching it off revokes
          # every token in the slot too.
          managedFiles = {
            ${i.api.clientsFile} = lib.optionalString i.api.enable (lib.concatMapStrings (
              a:
              let
                f = vars.${genOf name a}.files.sha256;
              in
              lib.optionalString f.exists "${a} ${lib.trim f.value}\n"
            ) (lib.sort lib.lessThan i.agents));
          };
        };
      }) enabled
    );

    clan.core.vars.generators = lib.mkMerge (
      lib.mapAttrsToList (
        name: i:
        lib.genAttrs (map (genOf name) i.agents) (
          gen:
          let
            agent = lib.removePrefix "${name}-api-" gen;
          in
          {
            files.token.restartUnits = [ "hermes-agent-${agent}.service" ];
            files.sha256.secret = false;
            runtimeInputs = [
              pkgs.openssl
              pkgs.coreutils
            ];
            script = ''
              openssl rand -hex 32 | tr -d '\n' > "$out"/token
              sha256sum "$out"/token | cut -d' ' -f1 | tr -d '\n' > "$out"/sha256
            '';
          }
        )
      ) withApi
    );

    services.hyperhermes.agents = lib.mkMerge (
      lib.mapAttrsToList (
        name: i:
        lib.genAttrs i.agents (
          a:
          {
            extraPackages = [ (wrapperOf name i) ];
            skillDirs = [ "${skillOf name i}/share/skills" ];
          }
          // lib.optionalAttrs i.api.enable {
            environment."${i.envPrefix}_API_URL" = urlOf i;
            secretEnv."${i.envPrefix}_API_TOKEN" = vars.${genOf name a}.files.token.path;
          }
        )
      ) enabled
    );

    hyper.ztEuLanGuard.noLan.allow = lib.mkMerge (
      lib.mapAttrsToList (
        _: i:
        lib.genAttrs (lib.filter (a: lib.elem a noLanUsers) i.agents) (_: [
          {
            address = addressOf i;
            ports = [ i.port ];
          }
        ])
      ) withApi
    );
  };
}
