# REA ("Reverse Engineer Anything", rea-agents, github.com/morluto/rea)
# for the agents that opt in (services.hyperhermes.agents.<name>.rea.enable):
# REA's stdio MCP server as hermes' mcp_servers.rea, the `rea` CLI and the
# analysis tools on the agent's PATH, and REA's reverse-engineer-anything
# skill (with its references/). The MCP entry and the CLI carry the same
# REA_* environment, so both reach every tool below at its store path;
# REA's own setup writes nothing (no `rea setup`, no downloads).
#
# Tools (REA's version pins checked in its source; overrides in
# ../../pkgs/rea-agents where nixpkgs differs):
#   - Ghidra 12.1.4 (REA's verified release) on JDK 21: the native
#     analysis provider (open_binary, decompile, xrefs, ...), pinned with
#     REA_ANALYSIS_PROVIDER since `auto` refuses two usable providers;
#   - Kuna 1.833 (verified release, prebuilt): the second provider, by
#     open_binary's provider_id "kuna";
#   - jadx-headless-mcp 0.7.1 (REA's pinned jar) for Android/DEX,
#     apktool, adb (android-tools);
#   - TShark/capinfos 4.x (wireshark-cli), sigrok-cli 0.7.2 (exact pin,
#     overridden), binwalk 3.1, unblob 26.6, WABT 1.0.42 (exact pin,
#     overridden), mitmdump 12.2.3 (exact pin), util-linux prlimit for
#     every resource-limited lane (REA defaults to /usr/bin/prlimit);
#   - rizin, GDB, all-targets GNU objdump, a Python with REA's exact
#     pwntools 4.15.0 / pyelftools 0.33 / unicorn 2.1.2 (overridden);
#   - Wakaru 1.14.0 (verified, prebuilt) for JavaScript source recovery,
#     Chromium for web module tracing and browser scenarios, ilspycmd
#     for .NET (REA's doctor checks it; the agent runs it itself);
#   - procps `ps` on PATH: REA refuses Linux child processes without it.
#
# Left out, and what is lost:
#   - Hopper, IDA, JEB: commercial; their providers stay unavailable.
#   - Frida: the npm binding's install script downloads a prebuilt
#     binary; the frida_* instrumentation tools report unavailable.
#   - pwndbg: not in nixpkgs (upstream builds it with uv2nix at an exact
#     2026.09.15 pin); only inspect_recorded_crash's optional debugger
#     context facet needs it.
#   - Cutter: REA talks to a running Cutter GUI through a plugin, which
#     a headless agent account does not have; list_cutter_sessions and
#     cutter_command stay empty.
#   - Ghidra NativeAOT extension (REA_GHIDRA_NATIVEAOT_JAR): built
#     locally from REA's sources, not shipped; NativeAOT recovery is off.
#   - macOS-only lanes (LLDB call tracing, native UI, Swift) do not apply.
#   - Electron scenarios launch the app named in the request; no Electron
#     is supplied.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes.rea;
  rea = cfg.package;

  wabt = pkgs.callPackage ../../pkgs/rea-agents/wabt.nix { };
  sigrok-cli = pkgs.callPackage ../../pkgs/rea-agents/sigrok-cli.nix { };
  pwntoolsPython = pkgs.callPackage ../../pkgs/rea-agents/pwntools-python.nix { };
  wakaru = pkgs.callPackage ../../pkgs/rea-agents/wakaru.nix { };
  kuna = pkgs.callPackage ../../pkgs/rea-agents/kuna.nix { };
  jadxMcpJar = pkgs.fetchurl {
    url = "https://github.com/1013503897/jadx-headless-mcp/releases/download/v0.7.1/jadx-headless-mcp-0.7.1-all.jar";
    hash = "sha256-bl6s9QC2QpK/tzxJeXwZWPbuRGRuQ+hoA5rn/rVz/3U=";
  };
  prlimit = "${pkgs.util-linux.bin}/bin/prlimit";

  # Out of the package: hermes' skill scanners skip every path with a
  # node_modules component (agent/skill_utils.py, EXCLUDED_SKILL_DIRS), so
  # the skill as shipped under lib/node_modules is never listed.
  skill = import ../../lib/agent-skill.nix pkgs {
    name = "reverse-engineer-anything";
    src = "${rea.skills}/reverse-engineer-anything";
  };

  environment = {
    GHIDRA_INSTALL_DIR = "${pkgs.ghidra}/lib/ghidra";
    JAVA_HOME = pkgs.jdk21.home;
    REA_ANALYSIS_PROVIDER = "ghidra";
    REA_KUNA_COMMAND = lib.getExe kuna;
    REA_JADX_MCP_JAR = "${jadxMcpJar}";
    REA_APKTOOL_COMMAND = lib.getExe pkgs.apktool;
    REA_ADB_PATH = "${pkgs.android-tools}/bin/adb";
    REA_TSHARK_COMMAND = "${pkgs.wireshark-cli}/bin/tshark";
    REA_CAPINFOS_COMMAND = "${pkgs.wireshark-cli}/bin/capinfos";
    REA_TSHARK_PRLIMIT_COMMAND = prlimit;
    REA_SIGROK_COMMAND = lib.getExe sigrok-cli;
    REA_SIGROK_PRLIMIT_COMMAND = prlimit;
    REA_BINWALK_COMMAND = lib.getExe pkgs.binwalk;
    REA_UNBLOB_COMMAND = lib.getExe pkgs.unblob;
    REA_FIRMWARE_PRLIMIT_COMMAND = prlimit;
    REA_EVM_PRLIMIT_COMMAND = prlimit;
    REA_WABT_BIN_DIRECTORY = "${wabt}/bin";
    REA_MITMDUMP_COMMAND = "${pkgs.mitmproxy}/bin/mitmdump";
    REA_RIZIN_COMMAND = "${pkgs.rizin}/bin/rizin";
    REA_OBJDUMP_COMMAND = "${pkgs.binutils-unwrapped-all-targets}/bin/objdump";
    REA_GDB_COMMAND = lib.getExe pkgs.gdb;
    REA_PWNTOOLS_PYTHON = "${pwntoolsPython}/bin/python3";
    REA_WAKARU_COMMAND = lib.getExe wakaru;
    REA_JAVASCRIPT_PRLIMIT_COMMAND = prlimit;
    REA_BROWSER_EXECUTABLE = lib.getExe pkgs.chromium;
    REA_ILSPY_CMD_PATH = lib.getExe pkgs.ilspycmd;
  };

  # The CLI with the MCP server's environment as defaults, so a shell
  # `rea` reaches the same tools; a caller's own value still wins.
  reaCli = pkgs.symlinkJoin {
    name = "rea-${rea.version}";
    paths = [ rea ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      for bin in rea rea-agents; do
        wrapProgram $out/bin/$bin ${
          lib.concatStringsSep " " (
            lib.mapAttrsToList (name: value: "--set-default ${name} ${lib.escapeShellArg value}") environment
          )
        }
      done
    '';
  };

  # On PATH next to `rea` for the agent's own use. objdump (all targets)
  # and the pwntools Python stay off it: they would shadow the agent's
  # binutils and its venv python.
  tools = [
    pkgs.procps
    pkgs.ghidra
    pkgs.jdk21
    kuna
    pkgs.apktool
    pkgs.android-tools
    pkgs.wireshark-cli
    sigrok-cli
    pkgs.binwalk
    pkgs.unblob
    wabt
    pkgs.mitmproxy
    pkgs.rizin
    pkgs.gdb
    wakaru
    pkgs.chromium
    pkgs.ilspycmd
  ];
in
{
  options.services.hyperhermes = {
    rea.package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../pkgs/rea-agents { };
      defaultText = lib.literalMD "rea-agents 6.8.0 (../../pkgs/rea-agents)";
      description = "The rea-agents package (the `rea` CLI and MCP server).";
    };

    agents = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, ... }:
          {
            options.rea.enable = lib.mkEnableOption ''
              REA (reverse engineering): its MCP server as mcp_servers.rea,
              the `rea` CLI with its analysis tools, and the
              reverse-engineer-anything skill'';
            config = lib.mkIf config.rea.enable {
              extraPackages = [ reaCli ] ++ tools;
              skillDirs = [ "${skill}/share/skills" ];
              settings.mcp_servers.rea = {
                command = "${rea.nodejs}/bin/node";
                args = [
                  rea.entrypoint
                  "mcp"
                ];
                env = environment;
                # REA's own client guidance: 30 s to start; a tool call
                # gets Ghidra's startup budget (import plus auto-analysis,
                # REA_GHIDRA_STARTUP_TIMEOUT_MS, 330 s) plus its 120 s
                # headroom, as REA's setup computes for Codex.
                connect_timeout = 30;
                timeout = 450;
              };
            };
          }
        )
      );
    };
  };
}
