{config, ...}: {
  imports = [./iodine-password.nix];
  services.iodine.clients.foo = {
    server = "ns.bruch-bu.de";
    passwordFile = config.clan.core.vars.generators.iodine-password.files.password.path;
  };
}
