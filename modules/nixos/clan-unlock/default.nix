{ pkgs, inputs, ... }:
{
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "clan-unlock";
      runtimeInputs = [
        inputs.clan-core.packages.x86_64-linux.clan-cli
        pkgs.openssh
      ];
      text = builtins.readFile ./clan-unlock.sh;
    })
  ];
}
