{lib, ...}: {
  # plugin fortisslvpn depends on lcevcdec which doesn't support riscv
  networking.networkmanager.plugins = lib.mkForce [];
}
