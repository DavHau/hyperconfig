let
  users' = {
    dave = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDuhpzDHBPvn8nv8RH1MRomDOaXyP4GziQm7r3MZ1Syk grmpf";
  };
  users = builtins.attrValues users';

  systems' = {
    nas = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICDLN5eXtO4Jy08bZcjNa7BI2NQtFHkEbpE5V7RiGLv4";
  };
  systems = builtins.attrValues systems';
in
with users';
with systems';
{
  "wifi-parasit.age".publicKeys = [dave nas];
  "monit-gmail".publicKeys = [dave nas];
}
