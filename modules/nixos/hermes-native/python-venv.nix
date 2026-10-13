# One writable, pip-capable python venv over a nixpkgs interpreter, as a
# unit factory. native.nix calls `mkUnit` once per agent;
# ../hermes-agents-gpu-host.nix reuses it on the GPU host. Vendored from
# spaces 6d744780 modules/nixos/hermes/python-venv.nix.
#
# Manylinux wheels work two ways. nix-ld loads standalone executables.
# LD_LIBRARY_PATH finds the extension modules. The nix-built interpreter
# dlopen's these modules. `wheelLibraryPath` is that LD_LIBRARY_PATH.
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
      pythonEnv = python.withPackages packages;
      venv = "${stateDir}/.venv";
    in
    {
      inherit venv;
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
