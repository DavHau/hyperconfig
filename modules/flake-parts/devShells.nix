{ self, lib, inputs, ... }: {
  perSystem = { config, self', inputs', pkgs, system, ... }:
    let
      clan-cli = inputs'.clan-core.packages.clan-cli;
      p2pSshPython = ../../modules/clan/p2p-ssh/python;

      clan-cli-with-p2p-ssh = clan-cli.overrideAttrs (old: {
        postInstall = old.postInstall + ''
          cp -r ${p2pSshPython}/clan_lib/network/p2p_ssh \
            $out/${clan-cli.passthru.pythonRuntime.sitePackages}/clan_lib/network/p2p_ssh
        '';
      });
    in
    {
      devShells.default = pkgs.mkShell {
        packages = [
          clan-cli-with-p2p-ssh
          # pkgs.esphome
        ];
      };
    };
}
