/*
  There are two roles: peers and controllers:
    - Every controller has an endpoint set
    - There can be multiple peers
    - There has to be one or more controllers
    - Peers connect to ALL controllers (full mesh)
    - If only one controller exists, peers automatically use it for IP allocation
    - If multiple controllers exist, peers must specify which controller's subnet to use
    - Controllers have IPv6 forwarding enabled, every peer and controller can reach
      everyone else, via extra controller hops if necessary

    Example:
              ┌───────────────────────────────┐
              │            ◄─────────────     │
              │ controller2              controller1
              │    ▲       ─────────────►    ▲     ▲
              │    │ │ │ │                 │ │   │ │
              │    │ │ │ │                 │ │   │ │
              │    │ │ │ │                 │ │   │ │
              │    │ │ │ └───────────────┐ │ │   │ │
              │    │ │ └──────────────┐  │ │ │   │ │
              │      ▼                │  ▼ ▼     ▼
              └─► peer2               │  peer1  peer3
                                      │          ▲
                                      └──────────┘

  Network Architecture:

  IPv6 Address Allocation:
    - Base network: /40 ULA prefix (generated from instance name)
    - Controllers: Each gets a /56 subnet from the base /40
    - Peers: Each gets a unique host suffix that is used in ALL controller subnets

  Address Assignment:
    - Each peer generates a unique 64-bit host suffix (e.g., :8750:a09b:0:1)
    - This suffix is appended to each controller's /56 prefix
    - Example: peer1 with suffix :8750:a09b:0:1 gets:
      - fd51:19c1:3b:f700:8750:a09b:0:1 in controller1's subnet
      - fd51:19c1:c1:aa00:8750:a09b:0:1 in controller2's subnet

  Peers: Use a SINGLE interface that:
    - Connects to ALL controllers
    - Has multiple IPs, one in each controller's subnet (with /56 prefix)
    - Routes to each controller's /56 subnet via that controller
    - allowedIPs: Each controller's /56 subnet
    - No routing conflicts due to unique IPs per subnet

  Controllers: Use a SINGLE interface that:
    - Connects to ALL peers and ALL other controllers
    - Gets a /56 subnet from the base /40 network
    - Has IPv6 forwarding enabled for routing between peers
    - allowedIPs:
      - For peers: A /96 range containing the peer's address in this controller's subnet
      - For other controllers: The controller's /56 subnet
*/

{
  clanLib,
  ...
}:
let
  # Shared module for extraHosts configuration
  extraHostsModule =
    {
      instanceName,
      settings,
      roles,
      config,
      lib,
      ...
    }:
    {
      networking.extraHosts =
        let
          domain = if settings.domain == null then instanceName else settings.domain;
          # Controllers use their subnet's ::1 address
          controllerHosts = lib.mapAttrsToList (
            name: _value:
            let
              prefix = clanLib.vars.getPublicValue {
                flake = config.clan.core.settings.directory;
                machine = name;
                generator = "wireguard-network-${instanceName}";
                file = "prefix";
              };
              # Controller IP is always ::1 in their subnet
              ip = prefix + "::1";
            in
            "${ip} ${name}.${domain}"
          ) roles.controller.machines;

          # Peers use their suffix in their designated controller's subnet only
          peerHosts = lib.mapAttrsToList (
            peerName: peerValue:
            let
              peerSuffix = clanLib.vars.getPublicValue {
                flake = config.clan.core.settings.directory;
                machine = peerName;
                generator = "wireguard-network-${instanceName}";
                file = "suffix";
              };
              # Determine designated controller
              designatedController =
                if (builtins.length (builtins.attrNames roles.controller.machines) == 1) then
                  (builtins.head (builtins.attrNames roles.controller.machines))
                else
                  peerValue.settings.controller;
              controllerPrefix = clanLib.vars.getPublicValue {
                flake = config.clan.core.settings.directory;
                machine = designatedController;
                generator = "wireguard-network-${instanceName}";
                file = "prefix";
              };
              peerIP = controllerPrefix + ":" + peerSuffix;
            in
            "${peerIP} ${peerName}.${domain}"
          ) roles.peer.machines or { };

          # External peers
          externalPeerHosts = lib.flatten (
            lib.mapAttrsToList (
              ctrlName: _ctrlValue:
              lib.mapAttrsToList (
                peer: _peerSettings:
                let
                  peerSuffix = builtins.readFile (
                    config.clan.core.settings.directory
                    + "/vars/shared/wireguard-network-${instanceName}-external-peer-${peer}/suffix/value"
                  );
                  controllerPrefix = builtins.readFile (
                    config.clan.core.settings.directory
                    + "/vars/per-machine/${ctrlName}/wireguard-network-${instanceName}/prefix/value"
                  );
                  peerIP = controllerPrefix + ":" + peerSuffix;
                in
                "${peerIP} ${peer}.${domain}"
              ) (roles.controller.machines.${ctrlName}.settings.externalPeers)
            ) roles.controller.machines
          );
        in
        builtins.concatStringsSep "\n" (controllerHosts ++ peerHosts ++ externalPeerHosts);
    };

  # Shared interface options
  sharedInterface =
    { lib, ... }:
    {
      options.port = lib.mkOption {
        type = lib.types.int;
        example = 51820;
        default = 51820;
        description = ''
          Port for the wireguard interface
        '';
      };

      options.domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        defaultText = lib.literalExpression "instanceName";
        default = null;
        description = ''
          Domain suffix to use for hostnames in /etc/hosts.
          Defaults to the instance name.
        '';
      };
    };
in
{
  _class = "clan.service";
  manifest.name = "clan-core/wireguard";
  manifest.description = "Wireguard-based VPN mesh network with automatic IPv6 address allocation";
  manifest.categories = [
    "System"
    "Network"
  ];
  manifest.readme = builtins.readFile ./README.md;

  # Peer options and configuration
  roles.peer = {
    description = "A peer that connects to one or more controllers.";
    interface =
      { lib, ... }:
      {
        imports = [ sharedInterface ];

        options.controller = lib.mkOption {
          type = lib.types.str;
          example = "controller1";
          description = ''
            Machinename of the controller to attach to
          '';
        };
      };

    perInstance =
      {
        instanceName,
        settings,
        roles,
        machine,
        ...
      }:
      {
        # Set default domain to instanceName

        # Peers connect to all controllers
        nixosModule =
          {
            config,
            pkgs,
            lib,
            ...
          }:
          {
            imports = [
              (extraHostsModule {
                inherit
                  instanceName
                  settings
                  roles
                  config
                  lib
                  ;
              })
            ];
            # Network allocation generator for this peer - generates host suffix
            clan.core.vars.generators."wireguard-network-${instanceName}" = {
              files.suffix.secret = false;

              runtimeInputs = with pkgs; [
                python3
              ];

              # Invalidate on hostname changes
              validation.hostname = machine.name;

              script = ''
                ${pkgs.python3}/bin/python3 ${./ipv6_allocator.py} "$out" "${instanceName}" peer "${machine.name}"
              '';
            };

            # Single wireguard interface with multiple IPs
            networking.wireguard.interfaces."${instanceName}" = {
              ips =
                # Get this peer's suffix
                let
                  peerSuffix =
                    config.clan.core.vars.generators."wireguard-network-${instanceName}".files.suffix.value;
                in
                # Create an IP in each controller's subnet
                lib.mapAttrsToList (
                  ctrlName: _:
                  let
                    controllerPrefix = clanLib.vars.getPublicValue {
                      flake = config.clan.core.settings.directory;
                      machine = ctrlName;
                      generator = "wireguard-network-${instanceName}";
                      file = "prefix";
                    };
                    peerIP = controllerPrefix + ":" + peerSuffix;
                  in
                  "${peerIP}/56"
                ) roles.controller.machines;

              privateKeyFile =
                config.clan.core.vars.generators."wireguard-keys-${instanceName}".files."privatekey".path;

              # Connect to all controllers
              peers = lib.mapAttrsToList (name: value: {
                publicKey = clanLib.vars.getPublicValue {
                  flake = config.clan.core.settings.directory;
                  machine = name;
                  generator = "wireguard-keys-${instanceName}";
                  file = "publickey";
                };

                # Allow each controller's /56 subnet
                allowedIPs = [
                  "${
                    clanLib.vars.getPublicValue {
                      flake = config.clan.core.settings.directory;
                      machine = name;
                      generator = "wireguard-network-${instanceName}";
                      file = "prefix";
                    }
                  }::/56"
                ];

                endpoint = "${value.settings.endpoint}:${toString value.settings.port}";

                persistentKeepalive = 25;
              }) roles.controller.machines;
            };
          };
      };
  };

  # Controller options and configuration
  roles.controller = {
    description = "A controller that routes peer traffic. Must be publicly reachable.";
    interface =
      { lib, ... }:
      {
        imports = [ sharedInterface ];

        options = {
          endpoint = lib.mkOption {
            type = lib.types.str;
            example = "vpn.clan.lol";
            description = ''
              Endpoint where the controller can be reached
            '';
          };
          ipv4 = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Enable IPv4 support for external peers on this controller.
                When enabled, the controller will have an IPv4 address and can route IPv4 traffic.

                IPv4 is only used for internet access, not for mesh communication (which uses IPv6).
              '';
            };
            address = lib.mkOption {
              type = lib.types.str;
              example = "10.42.1.1/24";
              description = ''
                IPv4 address for this controller in CIDR notation.
                External peers with IPv4 addresses must be within the same subnet.

                IPv4 is only used for internet access, not for mesh communication (which uses IPv6).
              '';
            };
          };
          externalPeers = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule {
                options = {
                  allowInternetAccess = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = ''
                      Whether to allow this external peer to access the internet through the controller.
                      When enabled, the controller will route internet traffic for this peer.

                      IPv4 is only used for internet access, not for mesh communication (which uses IPv6).
                    '';
                  };
                  ipv4.address = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    example = "10.42.1.50/32";
                    description = ''
                      IPv4 address for this external peer in CIDR notation.
                      The peer must be within the controller's IPv4 subnet.
                      Only used when the controller has IPv4 enabled.

                      IPv4 is only used for internet access, not for mesh communication (which uses IPv6).
                    '';
                  };
                };
              }
            );
            default = { };
            example = {
              dave = {
                allowInternetAccess = false;
              };
              "moms-phone" = {
                allowInternetAccess = true;
                ipv4.address = "10.42.1.51/32";
              };
            };
            description = ''
              External peers that are not part of the clan.

              For every entry here, a key pair for an external device will be generated.
              This key pair can then be displayed via `clan vars get` and inserted into an external device, like a phone or laptop.

              Each external peer can connect to the mesh through one or more controllers.
              To connect to multiple controllers, add the same peer name to multiple controllers' `externalPeers`, or simply set set `roles.controller.settings.externalPeers`.

              The external peer names must not collide with machine names in the clan.
              The machines which are part of the clan will be able to resolve the external peers via their host names, but not vice versa.
              External peers can still reach machines from within the clan via their IPv6 addresses.
            '';
          };
        };
      };
    perInstance =
      {
        settings,
        instanceName,
        roles,
        machine,
        ...
      }:
      {

        # Controllers connect to all peers and other controllers
        nixosModule =
          {
            config,
            pkgs,
            lib,
            ...
          }:
          let
            allOtherControllers = lib.filterAttrs (name: _v: name != machine.name) roles.controller.machines;
            allPeers = roles.peer.machines or { };
            # Collect all external peers from all controllers
            allExternalPeers = lib.unique (
              lib.flatten (
                lib.mapAttrsToList (_: ctrl: lib.attrNames ctrl.settings.externalPeers) roles.controller.machines
              )
            );

            controllerPrefix =
              controllerName:
              builtins.readFile (
                config.clan.core.settings.directory
                + "/vars/per-machine/${controllerName}/wireguard-network-${instanceName}/prefix/value"
              );

            peerSuffix =
              peerName:
              builtins.readFile (
                config.clan.core.settings.directory
                + "/vars/per-machine/${peerName}/wireguard-network-${instanceName}/suffix/value"
              );

            externalPeerSuffix =
              externalName:
              builtins.readFile (
                config.clan.core.settings.directory
                + "/vars/shared/wireguard-network-${instanceName}-external-peer-${externalName}/suffix/value"
              );

            thisControllerPrefix =
              config.clan.core.vars.generators."wireguard-network-${instanceName}".files.prefix.value;
          in
          {
            imports = [
              (extraHostsModule {
                inherit
                  instanceName
                  settings
                  roles
                  config
                  lib
                  ;
              })
            ];
            # Network prefix allocation generator for this controller
            clan.core.vars.generators = {
              "wireguard-network-${instanceName}" = {
                files.prefix.secret = false;

                runtimeInputs = with pkgs; [
                  python3
                ];

                # Invalidate on network or hostname changes
                validation.hostname = machine.name;

                script = ''
                  ${pkgs.python3}/bin/python3 ${./ipv6_allocator.py} "$out" "${instanceName}" controller "${machine.name}"
                '';
              };
            }
            # For external peers, generate: suffix, public key, private key
            // lib.genAttrs' (lib.attrNames settings.externalPeers) (peer: {
              name = "wireguard-network-${instanceName}-external-peer-${peer}";
              value = {
                files.suffix.secret = false;
                files.publickey.secret = false;
                files.privatekey.secret = true;
                files.privatekey.deploy = false;

                # The external peers keys are not deployed and are globally unique.
                # Even if an external peer is connected to more than one controller,
                # its private keys will remain the same.
                share = true;

                runtimeInputs = with pkgs; [
                  python3
                  wireguard-tools
                ];

                # Invalidate on hostname changes
                validation.hostname = peer;

                script = ''
                  ${pkgs.python3}/bin/python3 ${./ipv6_allocator.py} "$out" "${instanceName}" peer "${peer}"
                  wg genkey > $out/privatekey
                  wg pubkey < $out/privatekey > $out/publickey
                '';
              };
            });

            # Enable ip forwarding, so wireguard peers can reach each other
            boot.kernel.sysctl = {
              "net.ipv6.conf.all.forwarding" = 1;
            }
            // lib.optionalAttrs settings.ipv4.enable {
              "net.ipv4.conf.all.forwarding" = 1;
            };

            networking.firewall.allowedUDPPorts = [ settings.port ];

            networking.firewall.extraCommands =
              let
                peersWithInternetAccess = lib.filterAttrs (
                  _: peerConfig: peerConfig.allowInternetAccess
                ) settings.externalPeers;

                peerInfo = lib.mapAttrs (
                  peer: peerConfig:
                  let
                    ipv6Address = "${thisControllerPrefix}:${externalPeerSuffix peer}";
                    ipv4Address =
                      if settings.ipv4.enable && peerConfig.ipv4.address != null then
                        lib.head (lib.splitString "/" peerConfig.ipv4.address)
                      else
                        null;
                  in
                  {
                    inherit ipv6Address ipv4Address;
                  }
                ) peersWithInternetAccess;

              in
              lib.concatStringsSep "\n" (
                (lib.mapAttrsToList (_peer: info: ''
                  ip6tables -t nat -A POSTROUTING -s ${info.ipv6Address}/128 ! -o '${instanceName}' -j MASQUERADE
                '') peerInfo)
                ++ (lib.mapAttrsToList (
                  _peer: info:
                  lib.optionalString (info.ipv4Address != null) ''
                    iptables -t nat -A POSTROUTING -s ${info.ipv4Address} ! -o '${instanceName}' -j MASQUERADE
                  ''
                ) peerInfo)
              );

            # Single wireguard interface
            networking.wireguard.interfaces."${instanceName}" = {
              listenPort = settings.port;

              ips = [
                "${thisControllerPrefix}::1/40"
              ]
              ++ lib.optional settings.ipv4.enable settings.ipv4.address;

              privateKeyFile =
                config.clan.core.vars.generators."wireguard-keys-${instanceName}".files."privatekey".path;

              # Connect to all peers and other controllers
              peers =
                # Peers configuration
                (lib.mapAttrsToList (name: _value: {
                  publicKey = clanLib.vars.getPublicValue {
                    flake = config.clan.core.settings.directory;
                    machine = name;
                    generator = "wireguard-keys-${instanceName}";
                    file = "publickey";
                  };

                  # Allow the peer's /96 range in ALL controller subnets
                  allowedIPs = lib.mapAttrsToList (
                    ctrlName: _: "${controllerPrefix ctrlName}:${peerSuffix name}/96"
                  ) roles.controller.machines;

                  persistentKeepalive = 25;
                }) allPeers)
                ++
                  # External peers configuration - includes all external peers from all controllers
                  (map (
                    peer:
                    let
                      # IPv6 allowed IPs for mesh communication
                      ipv6AllowedIPs = lib.mapAttrsToList (
                        ctrlName: _: "${controllerPrefix ctrlName}:${externalPeerSuffix peer}/96"
                      ) roles.controller.machines;

                      # IPv4 allowed IP (only if this controller manages this peer and has IPv4 enabled)
                      ipv4AllowedIPs = lib.optional (
                        settings.ipv4.enable
                        && settings.externalPeers ? ${peer}
                        && settings.externalPeers.${peer}.ipv4.address != null
                      ) settings.externalPeers.${peer}.ipv4.address;
                    in
                    {
                      publicKey = clanLib.vars.getPublicValue {
                      flake = config.clan.core.settings.directory;
                      generator = "wireguard-network-${instanceName}-external-peer-${peer}";
                      shared = true;
                      file = "publickey";
                    };

                      allowedIPs = ipv6AllowedIPs ++ ipv4AllowedIPs;

                      persistentKeepalive = 25;
                    }
                  ) allExternalPeers)
                ++
                  # Other controllers configuration
                  (lib.mapAttrsToList (name: value: {
                    publicKey = clanLib.vars.getPublicValue {
                      flake = config.clan.core.settings.directory;
                      machine = name;
                      generator = "wireguard-keys-${instanceName}";
                      file = "publickey";
                    };

                    allowedIPs = [ "${controllerPrefix name}::/56" ];

                    endpoint = "${value.settings.endpoint}:${toString value.settings.port}";
                    persistentKeepalive = 25;
                  }) allOtherControllers);
            };
          };
      };
  };

  # Maps over all machines and produces one result per machine, regardless of role
  perMachine =
    { instances, machine, ... }:
    {
      nixosModule =
        { pkgs, lib, ... }:
        let
          # Check if this machine has conflicting roles across all instances
          machineRoleConflicts = lib.flatten (
            lib.mapAttrsToList (
              instanceName: instanceInfo:
              let
                isController =
                  instanceInfo.roles ? controller && instanceInfo.roles.controller.machines ? ${machine.name};
                isPeer = instanceInfo.roles ? peer && instanceInfo.roles.peer.machines or { } ? ${machine.name};
              in
              lib.optional (isController && isPeer) {
                inherit instanceName;
                machineName = machine.name;
              }
            ) instances
          );
        in
        {
          # Add assertions for role conflicts
          assertions = lib.forEach machineRoleConflicts (conflict: {
            assertion = false;
            message = ''
              Machine '${conflict.machineName}' cannot have both 'controller' and 'peer' roles in the wireguard instance '${conflict.instanceName}'.
              A machine must be either a controller or a peer, not both.
            '';
          });

          # Generate keys for each instance where this machine participates
          clan.core.vars.generators = lib.mapAttrs' (
            name: _instanceInfo:
            lib.nameValuePair "wireguard-keys-${name}" {
              files.publickey.secret = false;
              files.privatekey = { };

              runtimeInputs = with pkgs; [
                wireguard-tools
              ];

              script = ''
                wg genkey > $out/privatekey
                wg pubkey < $out/privatekey > $out/publickey
              '';
            }
          ) instances;

        };
    };
}
