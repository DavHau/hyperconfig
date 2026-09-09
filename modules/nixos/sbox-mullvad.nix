{inputs, ...}: {
  # Optional sbox front-end: `sbox --net-setup 'sbox-net-mullvad <location>'`
  # routes a single sandbox through Mullvad WireGuard, no config file needed.
  # First use registers a device key with the account of the local Mullvad
  # app (services.mullvad-vpn in vpn.nix); state in ~/.config/sbox/mullvad/.
  # No default location: sandboxes stay VPN-free unless asked
  # (set programs.sbox.mullvad.location to make it the default).
  imports = [inputs.sbox.nixosModules.sbox-mullvad];
  programs.sbox.mullvad.enable = true;
}
