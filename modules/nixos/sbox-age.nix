/*
  Shared age identity for sandboxes.

  One age keypair, generated once via clan vars (share = true) and deployed
  to every machine importing this module (all laptops via laptop-dave.nix).
  The identity file is group-readable by "users" so the desktop user can
  read it, and sbox mounts it read-only into the sandbox at
  ~/.config/age/identities.
*/
{ config, pkgs, ... }:
let
  identity = config.clan.core.vars.generators.sbox-age.files.identity;
in
{
  clan.core.vars.generators.sbox-age = {
    share = true;
    files.identity = {
      secret = true;
      group = "users";
      mode = "0440";
    };
    runtimeInputs = [ pkgs.age ];
    script = ''
      age-keygen > "$out"/identity
    '';
  };

  programs.sbox.bindReadOnly.${identity.path}.to = "$HOME/.config/age/identities";
}
