{ config, pkgs, ... }:
{
  # qemu
  boot.binfmt.emulatedSystems = [ "aarch64-linux" "armv7l-linux" "riscv64-linux" ];

  virtualisation.docker.enable = true;
  virtualisation.docker.rootless.enable = true;
  virtualisation.docker.rootless.setSocketVariable = true;
  # pasta, not the slirp4netns default: containers get IPv6, which is the
  # only address inference.p0.contact has inside the fleet, and one fewer
  # NAT hop for the rest. dockerd-rootless reads the backend from this
  # variable and finds the binary on the unit's PATH.
  virtualisation.docker.rootless.extraPackages = [ pkgs.passt ];
  systemd.user.services.docker.environment.DOCKERD_ROOTLESS_ROOTLESSKIT_NET = "pasta";
  # 256 compose networks instead of the ~30 the stock 172.17-31/16 pools
  # give: Harbor creates one per Terminal-Bench trial and leaks those of
  # failed trials, and a run at 10 agents exhausts the default in an hour.
  # The user's ~/.config/docker/daemon.json is not read; this is the file
  # dockerd-rootless is started with.
  virtualisation.docker.rootless.daemon.settings = {
    default-address-pools = [
      {
        base = "10.200.0.0/16";
        size = 24;
      }
      # v6 pools too, or compose networks come up v4-only and containers
      # cannot reach a v6-only host even though the namespace can.
      {
        base = "fd00:d0c:e5::/48";
        size = 64;
      }
    ];
    ipv6 = true;
    fixed-cidr-v6 = "fd00:d0c:e5:ffff::/64";
    ip6tables = true;
  };
  virtualisation.podman.enable = true;
  virtualisation.waydroid.enable = true;
  # virtualisation.podman.dockerSocket.enable = true;
  virtualisation.podman.extraPackages = [ pkgs.zfs ];
  systemd.services.podman.serviceConfig = {
    ExecStart = [ "" "${config.virtualisation.podman.package}/bin/podman --storage-driver zfs $LOGGING system service" ];
  };

  # virtualbox
  # virtualisation.virtualbox.host.enable = true;
  # users.extraGroups.vboxusers.members = [ "grmpf" ];
  # virtualisation.virtualbox.host.enableExtensionPack = true;
}
