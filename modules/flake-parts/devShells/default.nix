{ self, lib, inputs, ... }: {
  perSystem = { config, self', inputs', pkgs, system, ... }:
    let
      nixEvalCache = inputs.nix-eval-cache.packages.${system}.nix-cli;
      clan-fast = inputs.wrappers.lib.wrapPackage {
        inherit pkgs;
        package = inputs'.clan-core.packages.clan-cli;
        binName = "clan-fast";
        preHook = ''
          export PATH=${nixEvalCache}/bin:$PATH
          export _NIX_TRACING_CACHE_LOGGING=1
        '';
      };
      # nixpkgs' esphome cannot build esp32/esp-idf configs: pioarduino's
      # tool-esp_install runs idf_tools.py with a python that lacks the
      # platformio module (NixOS/nixpkgs#227230). Instead, run a pip-installed
      # esphome inside an FHS env so platformio manages its own toolchain.
      esphome-fhs = pkgs.buildFHSEnv {
        name = "esphome";
        targetPkgs = p: [
          p.python3
          p.git
          p.zlib
          p.libusb1
          p.udev
        ];
        profile = ''
          export ESPHOME_PIN=${pkgs.esphome.version}
        '';
        runScript = pkgs.writeShellApplication {
          name = "esphome-fhs";
          text = builtins.readFile ./esphome-fhs.sh;
        };
      };
    in
    {
      devShells.default = pkgs.mkShell {
        packages = [
          inputs'.clan-core.packages.clan-cli
          clan-fast
          esphome-fhs
        ];
      };

      devShells.mr-chatterbox = let
        python = pkgs.python3.withPackages (ps: [
          ps.torch
          ps.tokenizers
          ps.numpy
        ]);
      in pkgs.mkShell {
        packages = [ python ];
        shellHook = ''
          if [ ! -d .venv-mrchatterbox ]; then
            ${python}/bin/python -m venv .venv-mrchatterbox --system-site-packages
          fi
          source .venv-mrchatterbox/bin/activate
          pip install --quiet llm $HOME/projects/llm-mrchatterbox
          echo "Mr Chatterbox ready. Run: llm chat -m mrchatterbox"
        '';
      };
    };
}
