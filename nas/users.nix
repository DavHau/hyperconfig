{ config, lib, pkgs, ... }:
let
  home = "/pool11/enc/data/home";
in
{
  users.mutableUsers = false;
  users.users = {
    # root
    root = {
      hashedPassword =
        "$6$lOG0YKCp6YiW$Wb755rf4oWTwlBqfKZHgq5b5NN3M2TwOGovVI/gP8p27wI0NcneGKCn6LqK61UCdSIJ/0nohKSLTSBpJBqjSh/";
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDuhpzDHBPvn8nv8RH1MRomDOaXyP4GziQm7r3MZ1Syk grmpf"
      ];
    };

    # guest
    guest = {
      isNormalUser = true;
      home = "${home}/guest";
    };

    # users
    david = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      home = "${home}/david";
      openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys ++ [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE34Y0sKbX62j9OW3s0UBgx4TEp5cZGmpG4CN3sjddxG root@grmpf-nix"
      ];
      hashedPassword =
        "$6$lOG0YKCp6YiW$Wb755rf4oWTwlBqfKZHgq5b5NN3M2TwOGovVI/gP8p27wI0NcneGKCn6LqK61UCdSIJ/0nohKSLTSBpJBqjSh/";
    };

    # manu = {
    #   isNormalUser = true;
    #   extraGroups = [ "wheel" ];
    #   home = "${home}/manu";
    #   openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys;
    #   # SjbdXJPp7rGkFK6N
    #   hashedPassword =
    #     "$6$cSaQUHG9$AmiUTz6Dx4yKslHlm0ROr7hZXeV/3/LfRsSsKaaVeQbN3nAC6WFbJkjJBtKHOk703FUfyIX2LaNH6vmzTwpDU0";
    # };

    roman = {
      isNormalUser = true;
      home = "${home}/roman";
      openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys;
      hashedPassword =
        "$6$UMtBZdjDiCKHVih$xVMYP5dumKyXrgmrEnQApFxKhvgc.94FBjUGqQ1G35pNUaRqGaMdCZS9cCnOZVaZc0CjI7rmyLsrWeRroCSzv/";
    };
  };
}
