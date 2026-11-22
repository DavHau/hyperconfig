# Host keys of the SSH add-on on Roman's two Home Assistant Pis, pinned:
# keyscanned 2026-11-22 over zt-eu from som (uid roman). The add-on keeps
# its host key in its own data across updates; re-pin by hand only if
# the add-on is reinstalled. Used by machines/som/roman-home-assistant.nix.
{
  playa-pi = {
    hostNames = [ "192.168.10.3" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFaRsSdEGa2fixL8ZRZz0lUwu0g2Ti0NLWq4OGyOlTB7";
  };
  casa-pi = {
    hostNames = [ "192.168.20.3" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEjU/6hLZjt1tfCLGT0xiTmip4xQrGa18p3geGrehQq/";
  };
}
