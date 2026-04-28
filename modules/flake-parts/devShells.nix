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
    in
    {
      devShells.default = pkgs.mkShell {
        packages = [
          inputs'.clan-core.packages.clan-cli
          clan-fast
          # pkgs.esphome
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
