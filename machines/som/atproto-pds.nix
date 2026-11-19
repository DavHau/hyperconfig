# Dave's own atproto PDS at https://pds.davhau.com/ with his account
# dave.davhau.com (did:web:dave.davhau.com, served by the PDS at
# https://dave.davhau.com/.well-known/did.json), for signing in to his
# self-hosted Agave (docs/agave-self-hosted.md). The mechanism is
# ../../modules/nixos/atproto-pds; here only the names, the certificate and
# the DNS.
#
# Dave sets his password with `clan-secret-prompt som
# atproto-pds-dave-password password` and a deploy (random until then).
{ config, ... }:
let
  exposure = config.services.hyperhermes.exposure;
  pds = config.hyper.atprotoPds;
  names = [ pds.hostname ] ++ map (a: a.handle) (builtins.attrValues pds.accounts);
in
{
  imports = [ ../../modules/nixos/atproto-pds ];

  hyper.atprotoPds = {
    enable = true;
    hostname = "pds.davhau.com";
    handleDomain = "davhau.com";
    accounts.dave = {
      handle = "dave.davhau.com";
      email = "info@davhau.com";
    };
  };

  # One certificate for the PDS and the handle hosts, by DNS-01 like som's
  # other certificates (exposure's helper: porkbun, readable by nginx).
  security.acme.certs.${pds.hostname} = exposure.acmeCert pds.hostname // {
    extraDomainNames = builtins.tail names;
  };

  # *.davhau.com points at edi; these names come here instead. A: sgp's
  # IPv4, forwarded to som (../../modules/nixos/ipv4-forward.nix), AAAA: som's
  # own public address, as for teamclaude.davhau.com.
  hyper.porkbunRecords.records = builtins.listToAttrs (
    map (name: {
      inherit name;
      value = {
        A = exposure.publicIPv4;
        AAAA.ipv6OnLink = {
          inherit (config.networking.publicIPv6) interface;
          suffix = config.networking.publicIPv6.token;
        };
      };
    }) names
  );
}
