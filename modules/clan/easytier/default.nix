{ lib, ... }:
let
  inherit (lib)
    attrNames
    substring
    concatMapStrings
    ;
  inherit (builtins)
    hashString
    ;

  # the tun interface name is derived from the instance name
  getInterface = instanceName: substring 0 15 instanceName;

  # the ipv6 prefix is also derived from the instance name
  getIpv6Prefix = networkName:
    let
      hex = hashString "sha256" networkName;
      xx = fromIdx: substring fromIdx 2 hex;
      xxxx = fromIdx: substring fromIdx 4 hex;
    in
      "fd${xx 0}:${xxxx 2}:${xxxx 6}:${xxxx 10}";

  # each host's ipv6 is derived via their hostname
  getIpv6Address = prefix: hostName:
    let
      hex = hashString "sha256" hostName;
      xxxx = fromIdx: substring fromIdx 4 hex;
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
      { settings, instanceName, roles, machine, ... }:
      {
        nixosModule = {config, pkgs, inputs, ...}:
          let
            ipv6Prefix = getIpv6Prefix instanceName;
            ipv6Address = getIpv6Address ipv6Prefix machine.name;
            interface = getInterface instanceName;
            allHosts = attrNames roles.peer.machines;
          in
          {
            # vars
            clan.core.vars.generators."easytier-${instanceName}" = {
              files.shared-secret.secret = true;
              share = true;
              runtimeInputs = [
                pkgs.pwgen
              ];
              script = ''
                pwgen -s 32 1 > $out/shared-secret
              '';
            };

            # firewall
            networking.firewall.allowedTCPPorts = [
              11010
              11011
            ];
            networking.firewall.allowedUDPPorts = [
              11010
              11011
            ];

            # static hosts (dns)
            networking.extraHosts =
              concatMapStrings
                (host: "\n${getIpv6Address ipv6Prefix host} ${host}.${instanceName}")
                allHosts;

            # pre-service to update environment file with network_secret
            systemd.services."easytier-${instanceName}-update-env" = {
              description = "Update EasyTier environment file with shared secret";
              before = [ "easytier-${instanceName}.service" ];
              partOf = [ "easytier-${instanceName}.service" ];
              requiredBy = [ "easytier-${instanceName}.service" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = ''
                mkdir -p /run/secrets/easytier
                echo "ET_NETWORK_SECRET=\"$(cat ${config.clan.core.vars.generators."easytier-${instanceName}".files.shared-secret.path})\"" \
                  > "/run/secrets/easytier/${instanceName}.env"
              '';
            };

            # easytier
            services.easytier = {
              enable = true;
              package = pkgs.callPackage ./package.nix { easytier-src = inputs.easytier; };
              instances.${instanceName} = {
                environmentFiles = [
                  "/run/secrets/easytier/${instanceName}.env"
                ];
                settings = {
                  network_name = "${instanceName}2";
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
                  ipv6 = "${ipv6Address}/64";
                };
              };
            };
          };
      };
  };

}
