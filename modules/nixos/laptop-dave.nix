{ config, pkgs, lib, inputs, self, ... }:
let
  l = lib // builtins;
in
{
  imports = [
    inputs.home-manager.nixosModules.default
    inputs.retiolum.nixosModules.retiolum
    inputs.distro.nixosModules.noctalia-plugin
    ./opencrow-openrouter.nix
    ./common.nix
    ./common-tools.nix
    ./sbox.nix
    ./etc-hosts.nix
    ./nix-development.nix
    ./dns.nix
    ./nix.nix
    # ./hyprspace
    ./nrb
    ./nix-caches.nix
    ./niri.nix
    ./greetd.nix
    ./pi.nix
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
    inputs.distro.nixosModules.voxtype
  ];

  nixpkgs.pkgs =
    let
      # N.B. Keep in sync with default arg for stdenv/generic.
    defaultMkDerivationFromStdenv =
      stdenv: (import (inputs.nixpkgs + "/pkgs/stdenv/generic/make-derivation.nix") { inherit lib; inherit (pkgs) config; } stdenv).mkDerivation;
      withOldMkDerivation =
        stdenvSuperArgs: k: stdenvSelf:
        let
          mkDerivationFromStdenv-super =
            stdenvSuperArgs.mkDerivationFromStdenv or defaultMkDerivationFromStdenv;
          mkDerivationSuper = mkDerivationFromStdenv-super stdenvSelf;
        in
        k stdenvSelf mkDerivationSuper;
      # Wrap the original `mkDerivation` providing extra args to it.
      extendMkDerivationArgs =
        old: f:
        withOldMkDerivation old (
          _: mkDerivationSuper: args:
          (mkDerivationSuper args).overrideAttrs f
        );
      ignore = [
        "docker-runc"
        "efivar"
        "ipxe"
        "lib2geom"
        "libgcrypt"
        "libreoffice"
        "libtpms"
        "libyuv"
        "linux"
        "moby"
        "multipath-tools"
        "OVMF"
        "podman"
        "qtbase"
        "runc"
        "seabios"
        "sysdig"
        "syslinux"
        "systemd"
        "xen"
      ];
      withCFlags =
        compilerFlags: stdenv:
        stdenv.override (old: {
          mkDerivationFromStdenv = extendMkDerivationArgs old (args:
            if lib.elem args.pname or null ignore then
              args
            else if args ? NIX_CFLAGS_COMPILE then
              {
                NIX_CFLAGS_COMPILE = toString args.NIX_CFLAGS_COMPILE + " " + toString compilerFlags;
              }
            else
              {
                env = (args.env or { }) // {
                  NIX_CFLAGS_COMPILE = toString (args.env.NIX_CFLAGS_COMPILE or "") + " ${toString compilerFlags}";
                };
              });
        });
    in
    import inputs.nixpkgs {
      system = "x86_64-linux";
      config = (import ./nixpkgs-config.nix {inherit lib;});
      # config = (import ./nixpkgs-config.nix {inherit lib;}) // {
      #   replaceStdenv = ({ pkgs }: withCFlags [ "-funroll-loops" "-O3" "-march=x86-64-v3" ] pkgs.stdenv);
      # };
    };

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
  systemd.services.nix-daemon.environment.SSH_AUTH_SOCK = "/run/user/1000/ssh-agent";

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
