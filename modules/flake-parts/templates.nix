{ config, ... }:
{
  flake.templates = {
    minimal-clan = {
      path = ../../templates/minimal-clan;
      description = "Minimal clan: zerotier + yggdrasil overlay + p2p-ssh-iroh fallback, age vars backend with age-plugin-yubikey";
    };
    default = config.flake.templates.minimal-clan;
  };
}
