{lib, config, pkgs, ...}: {
  image.modules.disko-script-luks = {config, ...}: {
    imports = [
      ./resize-luks.nix
    ];
    system.build.image = config.system.build.diskoImagesScript;
    users.users.joy.initialPassword = "joy";
    users.users.joy.hashedPasswordFile = lib.mkForce null;
  };
}
