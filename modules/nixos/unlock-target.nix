# Where and how ../clan-unlock reaches this machine's initrd, so
# `clan-unlock <machine>` needs nothing else.
#
# The initrd carries a fixed link-local `address` on its LAN interface: no
# DHCP lease to guess, and unroutable, so clan-unlock jumps through `via`, a
# machine on the same link, using that machine's clan targetHost.
#
# The disk module (./zfs-remote-unlock, ./luks-unlock) supplies the initrd's
# `unlock` command, which reads the passphrase from stdin, and names the
# clan var holding it.
{ config, lib, ... }:
let
  cfg = config.hyper.unlockTarget;
in
{
  options.hyper.unlockTarget = {
    address = lib.mkOption {
      type = lib.types.strMatching "fe80::[0-9a-f:]+";
      example = "fe80::7a6e:1";
      description = "Fixed link-local address of the initrd.";
    };
    initrdNetwork = lib.mkOption {
      type = lib.types.str;
      example = "40-enp6s0";
      description = "boot.initrd.systemd.network network that gets `address`.";
    };
    lanInterface = lib.mkOption {
      type = lib.types.str;
      example = "br0";
      description = "This machine's LAN interface once booted, for when it is someone's `via`.";
    };
    via = lib.mkOption {
      type = lib.types.str;
      example = "vit";
      description = "Machine on the same link that clan-unlock jumps through.";
    };
    passphraseVar = lib.mkOption {
      type = lib.types.str;
      internal = true;
      description = "clan var with the passphrase `unlock` expects; set by the disk module.";
    };
  };

  config.boot.initrd.systemd.network.networks.${cfg.initrdNetwork}.address = [ "${cfg.address}/64" ];
}
