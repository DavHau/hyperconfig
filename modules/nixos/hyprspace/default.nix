{config, lib, pkgs, inputs, ...}: {

  imports = [
    inputs.hyprspace.nixosModules.default
  ];

  clan.core.vars.generators.hyprspace = {
    files.private-key.secret = true;
    files.peer-id.secret = false;
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprspace
      pkgs.jq
    ];
    script = ''
      hyprspace init --config ./config.json | tail -n +3 | jq -r .id | tr -d "\n" > $out/peer-id
      jq -r .privateKey ./config.json | tr -d "\n" > $out/private-key
    '';
  };

  services.hyprspace = {
    enable = true;

    # To get a private key and peer ID, use `hyprspace init`
    privateKeyFile = config.clan.core.vars.generators.hyprspace.files.private-key.path;

    # Same as the config file
    settings = {
      peers = [
        # { id = config.clan.core.vars.generators.hyprspace.files.peer-id.value; }
      ];
    };
  };
}
