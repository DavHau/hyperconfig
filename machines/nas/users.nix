{ config, lib, pkgs, ... }:
let
  home = "/pool11/enc/data/home";
in
{
  imports = [
    ../../modules/nixos/users/stefan.nix
  ];

  security.pam.services.sshd.unixAuth = lib.mkForce true;
  # this is needed for any of the custom sudo rules to take effect at all
  security.sudo.execWheelOnly = lib.mkForce false;
  security.sudo.extraRules = [
    {
      users = [ "stefen" ];
      commands = [
        {
          command = "${pkgs.systemd}/bin/systemctl stop voicinator";
          options = [ "NOPASSWD"];
        }
        {
          command = "${pkgs.systemd}/bin/systemctl start voicinator";
          options = [ "NOPASSWD"];
        }
        {
          command = "${pkgs.systemd}/bin/systemctl restart voicinator";
          options = [ "SETENV" "NOPASSWD"];
        }
        {
          command = "${pkgs.systemd}/bin/systemctl status voicinator";
          options = [ "NOPASSWD"];
        }
        {
          command = "${pkgs.systemd}/bin/journalctl -fu voicinator";
          options = [ "NOPASSWD"];
        }
      ];
    }
  ];
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
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUPqwy1ToPHzd5bG8TLqp26PkzA8HUeA3p4l34El80V root@nas"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJwzL0rt4J+kzggV4pFXf9yh9zBF6n4hdXXVbCB7p1x6 phone"
      ];
      # hashedPassword = "$6$0e8VNHlEiYMZiVMi$ouKAFUMdvrGrGeV/i7DhQgx16uu7RajCgj/aeQgm24ATlNcZPCF5lml8BoTFWzikZID2lIGaG.lVkvXXBklTK1";
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

    manu = {
      isNormalUser = true;
      home = "${home}/manu";
      openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys;
      hashedPassword =
        "$6$6/w4nx2ohs04F9vB$MOfFSA55VSINKbI5WohG.FrgN5XnrwoIgdM4hXghz3NW7yAjEPHWZ25zb0W6wX//qRSfROLyAmX8wdoM7zQcP/";
    };

    roman = {
      isNormalUser = true;
      home = "${home}/roman";
      openssh.authorizedKeys.keys =
        config.users.users.root.openssh.authorizedKeys.keys;
      hashedPassword =
        "$6$bE21GV8zsI0XywUq$avIpNZP2J5hCrQhkCOkpsPjjoSkQOUsNQAQa4ajCYAgDTLbAL7PK6bPuOR3Zw1lV3YvrxTaqHKc/HpYtC4sM/1";
    };

    stefan = {
      home = "${home}/stefan";
      openssh.authorizedKeys.keys =
        config.users.users.root.openssh.authorizedKeys.keys;
    };
  };
}
