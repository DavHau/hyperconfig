{ config, pkgs, lib, inputs, self, ... }:
let
  l = lib // builtins;
in
{
  imports = [
    inputs.home-manager.nixosModules.default
    inputs.retiolum.nixosModules.retiolum
    inputs.spaces.nixosModules.spaces
    ./pi-chat-openrouter.nix
    ./common.nix
    ./common-tools.nix
    ./sbox.nix
    ./ssh-tpm-agent.nix
    ./etc-hosts.nix
    ./nix-development.nix
    ./dns.nix
    ./nix.nix
    # ./hyprspace
    ./nrb
    ./nix-caches.nix
    # niri compositor + noctalia shell now come from distro.nixosModules.spaces
    # (above). The local ./niri.nix wired noctalia via niri's spawn-at-startup,
    # which bypassed the systemd user unit — so anything set on
    # systemd.user.services.noctalia-shell.environment (e.g. pi-chat's
    # NOCTALIA_NOTIF_HISTORY_FILE redirect) never reached the running shell.
    # Kept in-tree for reference until the distro-managed flow has been
    # exercised on this host.
    # ./niri.nix
    ./niri-monitor-binds.nix
    ./greetd.nix
    ./pi.nix
    ./omp-dual-anthropic.nix
    ./cpu-powersave-cap.nix
    ./amd-pstate-resume-fix.nix
    ./omr.nix
    ./proton-vpn.nix
    ./vpn.nix
    ./home-manager.nix
    ./fish.nix
    # fish-ai is now a home-manager module: ../home-manager/fish-ai.nix
    # ./backup.nix
    # ./retiolum.nix
    ./opengl.nix
    # ./cura.nix  # slicer for 3d printing
    # ./tplink-archer-t2u-nano.nix
    ./printing.nix
    ./nix-registry.nix
    ./low-battery-power-off.nix
    ./nix-lazy.nix
    ./nix-eval-cache.nix
    ./git.nix
    ./jujutsu.nix
    ./alacritty.nix
    ./udiskie.nix
    ./bitwarden.nix
    ./short-videos
    # ./envfs.nix
    # ./nix-heuristic-gc.nix
    ./ollama.nix
    ./fonts.nix
    ./gocr.nix
    ./ocr
    # ./nether.nix
    # ./vagrant.nix
    # ./iodine-client.nix
    ./udev.nix
    # ./sway
    # ./ups.nix
    ./packages.nix
    ./boot.nix
    ./desktop.nix
    ./audio.nix
    ./bluetooth.nix
    ./firewall.nix
    ./networking-desktop.nix
    ./virtualisation.nix
    ./ssh.nix
    ./locale.nix
    ./shell-aliases.nix
    ./nix-gc.nix
    ./pueue.nix
    ./wdisplays.nix
    # voxtype now arrives via inputs.spaces.nixosModules.spaces (above).
  ];

  nixpkgs.config = import ./nixpkgs-config.nix { inherit lib; };

  nixpkgs.hostPlatform = "x86_64-linux";

  clan.core.state.HOME.folders = [ "/home" ];

  # services.hyprspace.settings.peers = [
  #   { id = self.nixosConfigurations.nas.config.clan.core.vars.generators.hyprspace.files.peer-id.value; }
  # ];

  clan.core.networking.targetHost = lib.mkForce "root@localhost";

  # set by default via clan
  # sops.age.keyFile = "/home/grmpf/.config/sops/age/keys.txt";

  # NIX settings
  nix.nixPath = [
    "tb=/home/grmpf/synced/projects/github/nix-toolbox"
    "nixpkgs=${pkgs.path}"
  ];
  nix.settings.max-jobs = 40;
  # nix.buildMachines = [ {
  #   hostName = "bam.d";
  #   systems = [ "x86_64-linux" "aarch64-linux" ];
  #   maxJobs = 10;
  #   speedFactor = 20;
  #   supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" "uid-range" "ca-derivations" ];
  #   mandatoryFeatures = [ ];
  # }];

  # TLP
  # services.tlp.enable = true;
  # services.tlp.settings = {
  #   CPU_SCALING_GOVERNOR_ON_AC = "powersave";
  #   CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
  #   CPU_MAX_PERF_ON_AC = 100;
  #   STOP_CHARGE_THRESH_BAT0 = 100;
  #   START_CHARGE_THRESH_BAT0 = 85;
  #   CPU_SCALING_MAX_FREQ_ON_BAT = 1600000;
  #   CPU_SCALING_MAX_FREQ_ON_AC = 9999999;
  #   CPU_MAX_PERF_ON_BAT=40;
  # };
}
