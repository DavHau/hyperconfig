# VM test for hermes-guest-python.nix — the exact scenario the hermes
# agent kept fighting inside its microvm (see hermes-microvm.nix):
#
#   1. login shells resolve python3/pip from the writable venv;
#   2. the nix-preinstalled stack imports through --system-site-packages
#      (correct ABI — the interpreter and its site-packages agree);
#   3. `pip install` of a real manylinux wheel with C extensions works
#      AND the result imports — extension modules resolve libstdc++/libz
#      via LD_LIBRARY_PATH (nix-ld does not cover dlopen);
#   4. regression guard: without LD_LIBRARY_PATH the same import fails,
#      proving the env var is the load-bearing mechanism.
#
# The wheel is fetched at eval time (fixed-output), so the test itself
# runs offline; the cp314 wheel pins `python` to pkgs.python314 — bump
# both together when nixpkgs moves its python3 default.
{ pkgs }:
let
  # Real manylinux wheel whose extensions NEED system libstdc++/libz
  # (manylinux whitelist — auditwheel does not vendor those).
  numpyWheel = pkgs.fetchurl {
    url = "https://files.pythonhosted.org/packages/77/cc/70e59dcb84f2b005d4f306310ff0a892518cc0c8000a33d0e6faf7ca8d80/numpy-2.3.3-cp314-cp314-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl";
    hash = "sha256:ce020080e4a52426202bdb6f7691c65bb55e49f261f31a8f506c9f6bc7450421";
  };
  venv = "/var/lib/hermes/.venv";
in
pkgs.testers.runNixOSTest {
  name = "hermes-guest-python";

  nodes.machine = { pkgs, ... }: {
    imports = [ ./hermes-guest-python.nix ];

    services.hermes-python = {
      enable = true;
      user = "agent";
      python = pkgs.python314; # must match the cp314 test wheel
      packages = ps: [ ps.numpy ];
    };

    users.users.agent = {
      isNormalUser = true;
      group = "users";
    };
  };

  testScript = ''
    machine.wait_for_unit("hermes-python-venv.service")
    machine.wait_for_unit("multi-user.target")

    def sh(cmd):
        # login shell: same path the hermes terminal tool snapshots
        return machine.succeed(f"su - agent -c {cmd!r}")

    # 1. venv python/pip first on PATH for login shells
    out = sh("command -v python3 && command -v pip")
    assert out.split() == ["${venv}/bin/python3", "${venv}/bin/pip"], out

    # 2. preinstalled nix stack importable via --system-site-packages
    out = sh("python3 -c 'import numpy; print(numpy.__file__)'")
    assert out.startswith("/nix/store/"), out

    # 3. offline pip install of the manylinux wheel; must shadow the nix
    #    copy and actually compute (C extensions loaded). pip parses the
    #    wheel filename, so strip the store hash prefix first.
    wheel = "/tmp/numpy-2.3.3-cp314-cp314-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl"
    machine.succeed(f"install -m 0644 ${numpyWheel} {wheel}")
    sh(f"pip install --no-index --no-deps {wheel}")
    out = sh("python3 -c 'import numpy; print(numpy.__file__)'")
    assert out.startswith("${venv}/"), out
    sh("python3 -c 'import numpy; assert numpy.ones(3).sum() == 3.0'")

    # 4. LD_LIBRARY_PATH is the operative mechanism for wheel extensions
    machine.fail(
        "su - agent -c \"env -u LD_LIBRARY_PATH python3 -c 'import numpy'\""
    )
  '';
}
