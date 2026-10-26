# The local deployment on a workstation, in one import: hyperhermes runs in
# a NixOS container with a private network (`services.hyperhermes.
# localContainer`), the host reaches it at the same URLs the container
# serves, on its loopback only:
#
#   http://<agent>.hermes.localhost:8473          the agent's dashboard
#   http://<port>.<agent>.hermes.localhost:8473   a port the agent publishes
#   http://slot.<agent>.hermes.localhost:8473     the agent's slot, port 80
#   http://localhost:8473                         dex, the sign-in
#
# Browsers and glibc (nss-myhostname) resolve every *.localhost name to
# loopback, so nothing needs DNS. A socket-activated forward on the host's
# 127.0.0.1 and ::1 hands each connection to the container's nginx.
#
# `config` is the container's own NixOS config: services.hyperhermes.agents
# and whatever feature settings the deployment wants. nixosModules.default
# and ./guest.nix are imported there: local exposure, dex, dashboards,
# published ports and the browser tools on, every secret generated at the
# container's first boot (./guest.nix), agent slots nested in the
# container when an agent enables one.
#
# Sign in as <account>@hermes.localhost (the account owning an agent is the
# agent's name unless sso.accounts says otherwise) with the password
#   sudo nixos-container run <name> -- cat /var/lib/hyperhermes-local/dex/<account>.password
#
# Host side beyond the container and the forward: NAT for the container's
# veth (networking.nat), the agents' and the slots' only way out. NAT turns
# on IPv4 forwarding host-wide, so the container's web front accepts only
# hostAddress (./guest.nix): a LAN peer routing to localAddress through
# this host gets no answer. Agent slots are containers inside the
# container (a NixOS container's default privileges suffice for nested
# systemd-nspawn); each slot idmaps
# /nix/store, so the host's store must be on a file system that supports
# idmapped mounts (ext4, btrfs, xfs, zfs, tmpfs, erofs; not NFS, 9p or
# overlayfs).
{ hyperhermes }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes.localContainer;
  guest = config.containers.${cfg.name}.config;
  port = guest.services.hyperhermes.exposure.port;
  secretsDir = "/var/lib/hyperhermes-local";
in
{
  options.services.hyperhermes.localContainer = {
    enable = lib.mkEnableOption "hyperhermes in a local NixOS container, reachable from this host's loopback";

    name = lib.mkOption {
      type = lib.types.strMatching "[a-z][a-z0-9-]{0,10}";
      default = "hyperhermes";
      description = "Name of the container (at most 11 characters: its host veth is ve-<name>).";
    };

    hostAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.233.73.1";
      description = "The host's address on the container's veth.";
    };

    localAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.233.73.2";
      description = "The container's address on its veth; the forward dials it.";
    };

    config = lib.mkOption {
      type = lib.types.deferredModule;
      default = { };
      example = lib.literalExpression ''
        {
          services.hyperhermes.agents.alice = {
            uid = 1001;
            slot = { enable = true; id = 1; };
          };
        }
      '';
      description = "The container's NixOS config: the agents and feature settings (nixosModules.default and the local plumbing are imported).";
    };
  };

  config = lib.mkIf cfg.enable {
    containers.${cfg.name} = {
      autoStart = true;
      privateNetwork = true;
      inherit (cfg) hostAddress localAddress;
      config = {
        imports = [
          hyperhermes
          (import ./guest.nix {
            inherit (cfg) hostAddress localAddress;
            inherit secretsDir;
          })
          cfg.config
        ];
        system.stateVersion = lib.mkDefault config.system.stateVersion;
      };
    };

    # The container's web front admits hostAddress only (./guest.nix), so
    # the host's own connections must reach it from that address.
    # systemd-networkd would configure ve-* by its 80-container-ve.network:
    # a link-local and a /28 address, and masquerading of every address on
    # the link, which rewrites the forward's source to the /28. Here it
    # only brings the link up (the container's start waits for its
    # carrier); the containers module sets the address and the route.
    systemd.network.networks."10-ve-${cfg.name}" = lib.mkIf config.systemd.network.enable {
      matchConfig.Name = "ve-${cfg.name}";
      networkConfig = {
        LinkLocalAddressing = "no";
        KeepConfiguration = "yes";
      };
      linkConfig.RequiredForOnline = "no";
    };
    # Any other address on the veth stays out of the source selection.
    systemd.services."container@${cfg.name}".postStart = lib.mkAfter ''
      ip route replace ${cfg.localAddress} dev ve-${cfg.name} src ${cfg.hostAddress}
    '';

    # The host's loopback port, connection by connection into the container.
    systemd.sockets."hyperhermes-forward-${cfg.name}" = {
      description = "Loopback port of the local hyperhermes container ${cfg.name}";
      wantedBy = [ "sockets.target" ];
      listenStreams = [
        "127.0.0.1:${toString port}"
        "[::1]:${toString port}"
      ];
    };

    systemd.services."hyperhermes-forward-${cfg.name}" = {
      description = "Forward to the local hyperhermes container ${cfg.name}";
      requires = [ "container@${cfg.name}.service" ];
      after = [ "container@${cfg.name}.service" ];
      serviceConfig = {
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${cfg.localAddress}:${toString port}";
        DynamicUser = true;
      };
    };

    networking.nat = {
      enable = true;
      internalInterfaces = [ "ve-${cfg.name}" ];
    };
  };
}
