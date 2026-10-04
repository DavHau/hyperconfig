# Boot unlock through Tang servers on the LAN (./tang-server.nix): the
# initrd holds a secret clevis-encrypted to the servers' keys and asks one of
# them over link-local. Any one server suffices.
#
# This module only names the servers and packs clevis into the initrd; the
# disk-specific modules bind their own secret against `clevisPolicy` and do
# the unlocking (./zfs-remote-unlock, ./luks-unlock).
#
# Every server keeps its keys on its own encrypted root, so a set of stolen
# machines cannot unlock each other. After a full power cut the first machine
# is unlocked by hand and the rest follow.
{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.hyper.tangClient;
  servers = map (
    name:
    let
      server = inputs.self.nixosConfigurations.${name}.config;
    in
    {
      # The zone pins the link-local request to the initrd's LAN interface.
      url = "http://[${server.hyper.tangServer.address}%25${cfg.interface}]:7654";
      adv = server.clan.core.vars.generators.tang.files."adv.jws".value;
    }
  ) cfg.servers;
in
{
  options.hyper.tangClient = {
    servers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "vit" ];
      description = "Machines running hyper.tangServer that may unlock this one.";
    };
    interface = lib.mkOption {
      type = lib.types.str;
      example = "enp6s0";
      description = "The initrd's LAN interface, on the servers' link.";
    };
    enable = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = cfg.servers != [ ];
      defaultText = lib.literalExpression "servers != [ ]";
      description = "Whether any Tang server is configured.";
    };
    clevisPolicy = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      # Bound offline against the advertisements in the servers' public
      # vars, so binding needs neither the servers nor the network.
      default = builtins.toJSON {
        t = 1;
        pins.tang = map (s: {
          inherit (s) url;
          adv = "${pkgs.writeText "tang-adv.jws" s.adv}";
        }) servers;
      };
      defaultText = "sss policy over every server";
      description = "`clevis encrypt sss` policy for generators that bind a secret.";
    };
    validation = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      # A server rekey or address change regenerates every bound secret.
      default = builtins.toJSON servers;
      defaultText = "the servers' URLs and advertisements";
      description = "Value for the `validation` of generators that bind a secret.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Packs clevis, jose and curl into the initrd. No `devices`: the stock
    # hooks try once, the unlock modules here retry.
    boot.initrd.clevis.enable = true;
    boot.initrd.systemd.network.enable = true;
  };
}
