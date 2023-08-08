{inputs, ...}:
let
  secrets = builtins.readDir ./sops/secrets;

  secretsFiles =
    builtins.mapAttrs (name: _: ./sops/secrets/${name}/secret) secrets;

  mkSopsEntry = name: file: {
    sopsFile = file;
    format = "binary";
  };

in {
  imports = [
    inputs.sops-nix.nixosModules.sops
  ];
  sops.age.keyFile = "/home/grmpf/.config/sops/age/keys.txt";
  sops.secrets = builtins.mapAttrs mkSopsEntry secretsFiles;
}
