{config, ...}: {
  services.iodine.clients.foo = {
    server = "ns.bruch-bu.de";
    passwordFile = config.sops.secrets.iodine-password.path;
  };
}
