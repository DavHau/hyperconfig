{ config, lib, pkgs, ... }:
let
  home = "/pool11/enc/data/home";
in
{
  security.pam.services.sshd.unixAuth = lib.mkForce true;
  services.openssh.extraConfig = ''
    Match User roman
    PasswordAuthentication yes
    Match all
    PasswordAuthentication no
  '';
  users.mutableUsers = false;
  users.users = {
    # root
    root = {
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDuhpzDHBPvn8nv8RH1MRomDOaXyP4GziQm7r3MZ1Syk grmpf"
      ];
      hashedPassword = "$6$0e8VNHlEiYMZiVMi$ouKAFUMdvrGrGeV/i7DhQgx16uu7RajCgj/aeQgm24ATlNcZPCF5lml8BoTFWzikZID2lIGaG.lVkvXXBklTK1";
    };

    # guest
    guest = {
      isNormalUser = true;
      home = "${home}/guest";
    };

    # backup user
    # users
    backup = {
      isNormalUser = true;
      extraGroups = [];
      home = "${home}/backup";
      openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys ++ [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE34Y0sKbX62j9OW3s0UBgx4TEp5cZGmpG4CN3sjddxG root@grmpf-nix"
      ];
    };

    # users
    david = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      home = "${home}/david";
      openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys ++ [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDuhpzDHBPvn8nv8RH1MRomDOaXyP4GziQm7r3MZ1Syk grmpf"
      ];
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
      openssh.authorizedKeys.keys =
        config.users.users.root.openssh.authorizedKeys.keys;
      hashedPassword =
        "$6$bE21GV8zsI0XywUq$avIpNZP2J5hCrQhkCOkpsPjjoSkQOUsNQAQa4ajCYAgDTLbAL7PK6bPuOR3Zw1lV3YvrxTaqHKc/HpYtC4sM/1";
    };

    stefan = {
      isNormalUser = true;
      home = "${home}/stefan";
      openssh.authorizedKeys.keys =
        config.users.users.root.openssh.authorizedKeys.keys
        ++ [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA5PxR4yPCXBhL15II41hBF8V0d9D4ZRmICa3u09nNe8 hauer@MatebookX"
        ];
    };
  };
}
