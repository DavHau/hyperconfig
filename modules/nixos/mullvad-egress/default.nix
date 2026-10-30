# Mullvad egress for hyper.mullvadEgress.users (mechanism in ./egress.nix,
# their DNS in ./dns.nix), exiting in Singapore. The device is registered by
# ./register.sh, which fills the vars below; until then the listed users
# simply have no internet.
{ config, lib, ... }:
let
  vars = config.clan.core.vars.generators.mullvad-egress;
  device = builtins.fromJSON vars.files.device.value;
in
{
  imports = [
    ./egress.nix
    ./dns.nix
  ];

  # Not generated: a key is only useful once Mullvad knows it, so
  # register.sh creates, registers and stores it in one go.
  clan.core.vars.generators.mullvad-egress = {
    prompts.privateKey = {
      type = "hidden";
      persist = true;
      description = "WireGuard private key of the Mullvad device (set by register.sh)";
    };
    prompts.device = {
      persist = true;
      description = "Mullvad device as JSON: id, name, pubkey, addresses (set by register.sh)";
    };
    files.privateKey.owner = "systemd-network";
    files.device.secret = false;
  };

  hyper.mullvadEgress = {
    privateKeyFile = vars.files.privateKey.path;
    addresses = lib.optionals vars.files.device.exists [
      device.ipv4_address
      device.ipv6_address
    ];
    # sg-sin WireGuard relays from api.mullvad.net/public/relays/wireguard/v1,
    # alternating the two hosting providers so a failover also leaves the
    # provider. 2026-10-30: 001, 002, 101 and 102 stopped answering som's
    # handshakes (other relays, same key, did) and took the agents offline
    # for two hours, so the list now holds all six, the answering ones first.
    relays = [
      # sg-sin-wg-003
      {
        endpoint = "138.199.60.28:51820";
        publicKey = "3HtGdhEXUPKQIDRW49wCUoTK2ZXfq+QfzjfYoldNchg=";
      }
      # sg-sin-wg-103
      {
        endpoint = "135.136.98.130:51820";
        publicKey = "1YAc0lZSoqkzsO301Gmtnf43XwLWzchR8EcT5yGv9Qg=";
      }
      # sg-sin-wg-001
      {
        endpoint = "138.199.60.2:51820";
        publicKey = "sFHv/qzG7b6ds5pow+oAR3G5Wqp9eFbBD3BmEGBuUWU=";
      }
      # sg-sin-wg-101
      {
        endpoint = "146.70.199.2:51820";
        publicKey = "uR9bFQXY8nlBgYGTGAhHFPILocYJ5F0+YOhZMb7i6mI=";
      }
      # sg-sin-wg-002
      {
        endpoint = "138.199.60.15:51820";
        publicKey = "WM5I4IFwQcVysM4fF4NXZtQXNrSkqVWkQxNPPygOiF0=";
      }
      # sg-sin-wg-102
      {
        endpoint = "146.70.199.130:51820";
        publicKey = "uxHoFo9rroja6doGDTDln5u5MLxnkKxDdu/vyLVrqD8=";
      }
    ];
  };
}
