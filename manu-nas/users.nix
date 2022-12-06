{ config, lib, pkgs, ... }:
let
  home = "/pool11/enc/data/home";
in
{
  users.mutableUsers = false;
  users.users = {
    root = {
      hashedPassword =
        "$6$lOG0YKCp6YiW$Wb755rf4oWTwlBqfKZHgq5b5NN3M2TwOGovVI/gP8p27wI0NcneGKCn6LqK61UCdSIJ/0nohKSLTSBpJBqjSh/";
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDuhpzDHBPvn8nv8RH1MRomDOaXyP4GziQm7r3MZ1Syk grmpf"
      ];
    };
    manu = {
      isNormalUser = true;
      hashedPassword =
        "$6$hiNroqxtkx.i/iPZ$wzRqI7bV15gIyAJPGBM1NNoUfVUcysdEhUVnU5KEkrF4fkJG1zVikixT6BGcz7xoPPOaqTKoedZLOF/5sOOAq.";
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDuhpzDHBPvn8nv8RH1MRomDOaXyP4GziQm7r3MZ1Syk grmpf"
      ];
      extraGroups = ["manu"];
    };
  };
}
