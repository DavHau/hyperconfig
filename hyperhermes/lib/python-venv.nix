# One writable, pip-capable python venv over a nixpkgs interpreter, as a
# unit factory. The core module calls `mkUnit` once per agent; a host the
# agents ssh into (a GPU box) reuses it through `hyperhermes.lib.pythonVenv`.
#
# Manylinux wheels work two ways. nix-ld loads standalone executables.
# The nix-built interpreter dlopen's their extension modules, whose NEEDED
# libs (libz, libstdc++, ...) resolve through LD_LIBRARY_PATH:
# `wheelLibraryPath`. Only that interpreter gets it: its wrapper sets it,
# and a .pth file takes it out of os.environ again at startup. The dynamic
# loader read it at exec and keeps it for every later dlopen, so imports
# still find the libs; the interpreter's children never see it. In a
# unit's or shell's environment it reached every program an agent runs,
# and a program from another nixpkgs then loaded these libs instead of its
# own (the system nix, built on its own nixpkgs: "GLIBC_2.43 not found
# (required by libcurl.so.4)"). Not patchelf: agents pip-install wheels at
# runtime. Known edges where the path still reaches children: `python -S`
# (no site, so no .pth) and a venv made FROM the agent venv without
# --system-site-packages (same wrapper, can't see the .pth).
{ lib, pkgs }:
rec {
  nixLdLibraries = with pkgs; [
    stdenv.cc.cc
    zlib
    zstd
    openssl
    curl
    expat
    libxml2
    libxslt
    libffi
    bzip2
    ncurses
    fontconfig
    freetype
  ];

  wheelLibraryPath = lib.makeLibraryPath nixLdLibraries;

  # `python.withPackages packages` whose interpreter alone sees
  # wheelLibraryPath (see the header).
  mkPythonEnv =
    python: packages:
    let
      # site runs a .pth line that starts with `import`. It removes exactly
      # what the wrapper prepended; a caller's own value stays.
      unexport = python.pkgs.toPythonModule (
        pkgs.writeTextFile {
          name = "hyperhermes-wheel-libs";
          destination = "/${python.sitePackages}/hyperhermes_wheel_libs.pth";
          text = ''
            import os; _p = ${builtins.toJSON wheelLibraryPath}; _v = os.environ.get("LD_LIBRARY_PATH", ""); _r = _v[len(_p):].lstrip(":") if _v.startswith(_p) else _v; (os.environ.__setitem__("LD_LIBRARY_PATH", _r) if _r else os.environ.pop("LD_LIBRARY_PATH", None)) if _r != _v else None
          '';
        }
      );
    in
    python.buildEnv.override {
      extraLibs = packages python.pkgs ++ [ unexport ];
      makeWrapperArgs = [
        "--prefix"
        "LD_LIBRARY_PATH"
        ":"
        wheelLibraryPath
      ];
    };

  mkUnit =
    {
      # Unit name suffix, "-<user>".
      suffix,
      user,
      group,
      stateDir,
      python,
      packages,
    }:
    let
      pythonEnv = mkPythonEnv python packages;
      venv = "${stateDir}/.venv";
    in
    {
      inherit venv pythonEnv;
      unitName = "hermes-python-venv${suffix}";

      services."hermes-python-venv${suffix}" = {
        description = "Hermes python venv (pip-writable)";
        wantedBy = [ "multi-user.target" ];
        unitConfig.RequiresMountsFor = [ stateDir ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          venv=${venv}
          mkdir -p ${stateDir}
          if [ ! -x "$venv/bin/python" ] \
             || [ "$(cat "$venv/.nix-python" 2>/dev/null || true)" != "${pythonEnv}" ]; then
            rm -rf "$venv"
            ${pythonEnv}/bin/python -m venv --system-site-packages "$venv"
            printf '%s' "${pythonEnv}" > "$venv/.nix-python"
            chown -R ${user}:${group} "$venv"
          fi
        '';
      };
    };
}
