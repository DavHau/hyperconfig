{ lib, ... }:
let
  inherit (lib)
    hashString
    substring
    ;

  getInterface = instanceName: substring 0 16 instanceName;

  getIpv6Prefix = networkName:
    let
      hex = hashString "sha256" networkName;
      xx = fromIdx: substring fromIdx (fromIdx + 2) hex;
      xxxx = fromIdx: substring fromIdx (fromIdx + 4) hex;
    in
      "fd${xx 0}:${xxxx 2}:${xxxx 6}${xxxx 10}";

  getIpv6Address = prefix: hostName:
    let
      hex = hashString "sha256" hostName;
      xxxx = fromIdx: substring fromIdx (fromIdx + 4) hex;
    in
      "${prefix}:${xxxx 0}:${xxxx 4}:${xxxx 8}:${xxxx 12}";
in
{
  _class = "clan.service";
  manifest.name = "easytier";
  manifest.description = "Easytier decentralized VPN";
  manifest.categories = [ "Utility" ];

  roles.peer = {

    perInstance =
      { settings, instanceName, ... }:
      let
        ipv6Prefix = getIpv6Prefix settings.network_name;
        ipv6Address = getIpv6Address ipv6Prefix instanceName;
        interface = getInterface instanceName;
      in
      {
        nixosModule = {
          clan.core.vars.generators."easytier-${instanceName}" = {
            files.shared-secret.secret = true;
            script = ''
              < /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32 > $out/shared-secret
            '';
          };
          services.easytier = {
            enable = true;
            instances.default = {
              settings = {
                network_name = instanceName;
                network_secret = "pick_a_secret";
                listeners = [
                  "tcp://0.0.0.0:11010"
                ];
                peers = [
                  "tcp://public.easytier.cn:11010"
                ];
                dhcp = true;
              };
              extraSettings = {
                flags.dev_name = interface;
              };
            };
          };
          systemd.network.networks."09-easytier" = {
            matchConfig.Name = interface;
            networkConfig = {
              LLDP = true;
              MulticastDNS = true;
              KeepConfiguration = "static";
            };
            address = [
              "${ipv6Address}/64"
            ];
          };
        };
      };
  };

  networking.firewall.allowedTCPPorts = [
    11010
    11011
  ];
  networking.firewall.allowedUDPPorts = [
    11010
    11011
  ];
}
