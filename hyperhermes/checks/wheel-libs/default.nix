# The venv's wheel libraries (lib/python-venv.nix, wheelLibraryPath) reach
# the venv's interpreter and nothing else. In a systemd-nspawn container
# (no VM), with alice's gateway running:
# - a command started the way hermes' terminal tool starts one
#   (tools/environments/local.py, LocalEnvironment: login-shell snapshot,
#   then the command), from the gateway process's real environment, cwd
#   and uid, has no LD_LIBRARY_PATH, and the system's nix, curl and git
#   run there. Before, the unit exported wheelLibraryPath, every child
#   inherited it, and a system program from another nixpkgs loaded those
#   libs instead of its own (som: the system nix, "GLIBC_2.43 not found
#   (required by libcurl.so.4)");
# - so does a login shell of alice (the profile used to export it too);
# - the gateway's hermes imports its native modules, and the venv's
#   python, run from that terminal, still loads the wheel libraries
#   (libxslt, libfontconfig: not in the interpreter's closure) while its
#   own children again see none.
# `nixPackage` is the container's nix: a host's own (som's, built on
# another nixpkgs) reproduces the real failure, not only the variable.
{
  pkgs,
  self,
  nixPackage ? pkgs.nix,
}:
let
  inherit (pkgs) lib;
  pythonVenv = self.lib.pythonVenv pkgs;
  wheelDirs = lib.splitString ":" pythonVenv.wheelLibraryPath;

  # Runs a python script as the gateway process: its environment, uid,
  # gid and working directory, read from /proc.
  asGateway = pkgs.writeShellScript "as-gateway" ''
    set -eu
    pid=$(systemctl show -p MainPID --value hermes-agent-alice.service)
    [ "$pid" != 0 ]
    mapfile -d "" envv < /proc/$pid/environ
    cd "$(readlink /proc/$pid/cwd)"
    # argv[0], hermes-agent-env's python (exe is the bare interpreter).
    py=$(${pkgs.coreutils}/bin/tr '\0' '\n' < /proc/$pid/cmdline | ${pkgs.coreutils}/bin/head -n1)
    exec ${pkgs.util-linux}/bin/setpriv --reuid="$(stat -c %u /proc/$pid)" \
      --regid="$(stat -c %g /proc/$pid)" --clear-groups \
      ${pkgs.coreutils}/bin/env -i "''${envv[@]}" "$py" "$@"
  '';

  terminal = pkgs.writeText "terminal.py" ''
    import json, os, sys
    from tools.environments.local import LocalEnvironment
    env = LocalEnvironment(cwd=os.getcwd(), timeout=120)
    result = env.execute(sys.argv[1], timeout=120)
    print(json.dumps(result))
    sys.exit(result["returncode"])
  '';

  # Run by the venv's python from the terminal.
  venvProbe = pkgs.writeText "venv-probe.py" ''
    import ctypes, os, subprocess
    ctypes.CDLL("libxslt.so.1")
    ctypes.CDLL("libfontconfig.so.1")
    child = subprocess.run(["sh", "-c", "echo ''${LD_LIBRARY_PATH-unset}"],
                           capture_output=True, text=True, check=True).stdout.strip()
    print("venv-ok", os.environ.get("LD_LIBRARY_PATH", "unset"), child)
  '';
in
pkgs.testers.runNixOSTest {
  name = "hyperhermes-wheel-libs";

  containers.machine = {
    imports = [ self.nixosModules.core ];
    services.hyperhermes = {
      # The unit and its venv, not torch.
      pythonPackages = _: [ ];
      agents.alice.uid = 1001;
    };
    environment.systemPackages = [
      pkgs.curl
      pkgs.git
    ];
    nix.package = nixPackage;
  };

  testScript = ''
    import json
    import shlex
    wheel_dirs = ${builtins.toJSON wheelDirs}

    def no_wheel_libs(value, what):
        assert value == "unset" or not any(d in value for d in wheel_dirs), f"{what}: LD_LIBRARY_PATH={value}"

    def terminal(cmd):
        status, out = machine.execute(f"${asGateway} ${terminal} {shlex.quote(cmd)}")
        assert status == 0, out
        return json.loads(out.strip().splitlines()[-1])["output"]

    machine.wait_for_unit("hermes-python-venv-alice.service")
    machine.wait_for_unit("hermes-agent-alice.service")

    with subtest("a terminal command runs the system's nix, curl and git"):
        for tool, want in (("nix", "nix (Nix)"), ("curl", "curl "), ("git", "git version")):
            out = terminal(f"/run/current-system/sw/bin/{tool} --version 2>&1; echo rc=$?")
            print(out)
            assert want in out and "rc=0" in out, (tool, out)

    with subtest("a terminal command and the gateway have no wheel libraries"):
        no_wheel_libs(terminal('echo "''${LD_LIBRARY_PATH-unset}"').strip(), "terminal")
        pid = machine.succeed("systemctl show -p MainPID --value hermes-agent-alice.service").strip()
        environ = machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ")
        ld = next((l.split("=", 1)[1] for l in environ.splitlines() if l.startswith("LD_LIBRARY_PATH=")), "unset")
        no_wheel_libs(ld, "gateway")

    with subtest("alice's login shell has no wheel libraries"):
        no_wheel_libs(machine.succeed("runuser -u alice -- bash -lc 'echo ''${LD_LIBRARY_PATH-unset}'").strip(), "login shell")

    with subtest("hermes imports its native modules in the gateway's environment"):
        machine.succeed("${asGateway} -c 'import cryptography.hazmat.bindings._rust, pydantic_core, tokenizers, jiter, yaml, _cffi_backend, ssl, sqlite3'")

    with subtest("the venv's python loads the wheel libraries; its children do not get them"):
        out = terminal("python ${venvProbe}")
        line = next(l for l in out.splitlines() if l.startswith("venv-ok"))
        _, own, child = line.split(" ", 2)
        no_wheel_libs(own, "venv python's os.environ")
        no_wheel_libs(child, "venv python's child")
  '';
}
