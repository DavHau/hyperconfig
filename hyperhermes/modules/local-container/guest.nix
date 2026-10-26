# Inside the local container (./default.nix): the plumbing that makes the
# deployment's own config (agents, features) a working local deployment.
#
#   - exposure in local mode, nginx also on the container's address for the
#     host's forward; dex (sso), the dashboards, the published ports and
#     the browser tools on unless the deployment turns them off. Every
#     agent's dashboard is owned by a dex account of the agent's name
#     unless sso.accounts says otherwise.
#   - secrets: every secret option defaults to a file below `secretsDir`,
#     which hyperhermes-local-secrets fills at boot where a file is
#     missing: the OIDC client secrets, the published ports' cookie secret,
#     one dex password per account (and its bcrypt hash, which dex reads),
#     and each agent's ssh key pair (its sshKeyFile and, for slots, the key
#     its slot admits). Nothing is regenerated once it exists; delete a
#     file (for a dex account: its .password or .hash) and restart the
#     unit to rotate it.
#   - network: systemd-networkd with resolved (the host's resolv.conf may
#     name a stub listener on the host's loopback, which this network
#     namespace cannot reach), the container's address on eth0 as the
#     containers module sets it.
#   - agent slots (`agents.<name>.slot`): container slots nested in this
#     container. A dummy link stands in for the LAN NIC the slots' bridge
#     wants; the slots' own connections leave through eth0 (the egress
#     link of ../container-slots.nix), masqueraded to the container's
#     address and again by the host's NAT. No public IPv4, so no ports;
#     their IPv6 /128s sit in a ULA prefix that goes nowhere.
{
  hostAddress,
  localAddress,
  secretsDir,
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  hh = config.services.hyperhermes;
  agents = hh.agents;
  slotAgents = lib.filterAttrs (_: a: a.slot.enable) agents;
  slotsOn = slotAgents != { };
  egressTable = 8473;
  uplink = "slots-uplink";

  generate = pkgs.writeShellScript "hyperhermes-local-secrets" ''
    set -eu
    umask 077
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.openssh
        pkgs.openssl
        pkgs.mkpasswd
      ]
    }
    d=${secretsDir}
    install -d -m 0711 "$d" "$d/agents"
    install -d -m 0700 "$d/clients" "$d/dex"

    for id in ${lib.escapeShellArgs (lib.attrNames hh.sso.oidcClients)}; do
      [ -s "$d/clients/$id" ] || openssl rand -hex 32 | tr -d '\n' >"$d/clients/$id"
    done
    # 32 hex characters: a raw 32-byte secret to oauth2-proxy.
    [ -s "$d/publish-cookie" ] || openssl rand -hex 16 | tr -d '\n' >"$d/publish-cookie"

    for account in ${lib.escapeShellArgs (lib.attrNames hh.sso.dex.users)}; do
      if [ ! -s "$d/dex/$account.hash" ] || [ ! -s "$d/dex/$account.password" ]; then
        openssl rand -base64 18 | tr '+/' '-_' | tr -d '\n' >"$d/dex/$account.password"
        mkpasswd --method=bcrypt --rounds=10 --stdin <"$d/dex/$account.password" \
          | tr -d '\n' >"$d/dex/$account.hash.new"
        mv "$d/dex/$account.hash.new" "$d/dex/$account.hash"
      fi
    done

    # The agent's directory is root's: an agent owning it could swap a file
    # for a link that the chown and chmod here, or a slot start reading
    # key.pub, would follow as root. Only the private key is the agent's.
    for agent in ${lib.escapeShellArgs (lib.attrNames agents)}; do
      k="$d/agents/$agent"
      install -d -m 0755 -o root -g root "$k"
      if [ -L "$k/key" ] || [ -L "$k/key.pub" ] || [ ! -f "$k/key" ] || [ ! -f "$k/key.pub" ] \
        || [ ! -s "$k/key" ] || [ ! -s "$k/key.pub" ]; then
        rm -f "$k/key" "$k/key.pub"
        ssh-keygen -q -t ed25519 -N "" -C "$agent@hyperhermes" -f "$k/key"
      fi
      chown root:root "$k/key.pub"
      chown "$agent" "$k/key"
      chmod 0400 "$k/key"
      chmod 0444 "$k/key.pub"
    done
  '';
in
{
  imports = [
    # Defaults for the secret paths of every agent, dex account and OIDC
    # client, by redeclaring the submodules (the options' own modules merge
    # with these).
    {
      options.services.hyperhermes = {
        agents = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule (
              { name, config, ... }:
              {
                config = {
                  sshKeyFile = lib.mkDefault "${secretsDir}/agents/${name}/key";
                  slot.deployKeyFile = lib.mkIf (config.slot.deployKey == null) (
                    lib.mkDefault "${secretsDir}/agents/${name}/key.pub"
                  );
                };
              }
            )
          );
        };
        sso.dex.users = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule (
              { name, ... }:
              {
                passwordHashFile = lib.mkDefault "${secretsDir}/dex/${name}.hash";
              }
            )
          );
        };
      };
    }
  ];

  config = lib.mkMerge [
    {
      networking.useNetworkd = true;
      networking.useDHCP = false;
      networking.useHostResolvConf = false;
      services.resolved.enable = true;
      # The address and routes the containers module sets on eth0 before
      # init, declared so networkd keeps them.
      systemd.network.networks."40-eth0" = {
        matchConfig.Name = "eth0";
        address = [ "${localAddress}/32" ];
        routes = [
          { Destination = "${hostAddress}/32"; }
          {
            Gateway = hostAddress;
            GatewayOnLink = true;
          }
        ];
      };
      # The host's forward is the only client, always from hostAddress; the
      # host forwards IPv4 for its NAT, so anyone routing to the container's
      # subnet through it would reach an open port.
      networking.firewall.extraInputRules = "ip saddr ${hostAddress} tcp dport ${toString hh.exposure.port} accept";
      networking.firewall.extraCommands =
        lib.mkIf (config.networking.firewall.backend == "iptables")
          "iptables -A nixos-fw -p tcp -s ${hostAddress} --dport ${toString hh.exposure.port} -j nixos-fw-accept";

      services.hyperhermes = {
        exposure = {
          enable = true;
          mode = "local";
          listenAddresses = [
            "127.0.0.1"
            "[::1]"
            localAddress
          ];
        };
        sso = {
          enable = lib.mkDefault true;
          accounts = lib.mapAttrs (name: _: lib.mkDefault name) agents;
          dex.users = lib.genAttrs (lib.unique (lib.attrValues hh.sso.accounts)) (_: { });
          clients = lib.mapAttrs (id: _: {
            secretFile = lib.mkDefault "${secretsDir}/clients/${id}";
          }) hh.sso.oidcClients;
        };
        dashboards.enable = lib.mkDefault true;
        publish = {
          enable = lib.mkDefault true;
          cookieSecretFile = lib.mkDefault "${secretsDir}/publish-cookie";
        };
        browser.enable = lib.mkDefault true;
      };

      systemd.services.hyperhermes-local-secrets = {
        description = "Secrets of the local hyperhermes deployment";
        wantedBy = [ "multi-user.target" ];
        before = config.systemd.services.hyperhermes-local-secrets.requiredBy;
        requiredBy = [
          "dex.service"
          "oauth2-proxy-serve.service"
        ]
        ++ map (agent: "hermes-agent-${agent}.service") (lib.attrNames agents)
        ++ map (agent: "container@${agent}.service") (lib.attrNames slotAgents);
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = generate;
        };
      };
      # The published ports' login reads the issuer's discovery at start.
      systemd.services.oauth2-proxy-serve.after = [ "dex.service" ];
    }

    (lib.mkIf slotsOn {
      systemd.network.netdevs."10-${uplink}".netdevConfig = {
        Kind = "dummy";
        Name = uplink;
      };
      systemd.network.networks."40-${uplink}".matchConfig.Name = uplink;
      # No LAN to ask: the bridge only carries the slots' proxy NDP and the
      # egress routing rule.
      systemd.network.networks."40-br0" = {
        DHCP = lib.mkForce "no";
        networkConfig.ConfigureWithoutCarrier = true;
      };
      systemd.network.networks."40-eth0".routes = [
        {
          Gateway = hostAddress;
          GatewayOnLink = true;
          Table = egressTable;
        }
      ];
      networking.firewall.checkReversePath = "loose";

      services.container-slots = {
        enable = true;
        inherit uplink;
        uplinkMac = "02:68:68:00:00:01";
        lanIPv4 = "${hostAddress}/32";
        ipv6Prefix = "fd68:6868:6868:1";
        deployKeys = [ ];
        isolatedEgress = {
          interface = "eth0";
          table = egressTable;
        };
      };
      services.hyperhermes.slots = {
        egress = "the workstation's own connection (NAT through the container's host)";
        publicIPv6 = false;
      };
    })
  ];
}
