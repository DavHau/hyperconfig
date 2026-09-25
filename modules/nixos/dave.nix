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
    ./sbox-age.nix
    ./sbox-mullvad.nix
    ./nix-ssh-client.nix
    ./hermes-desktop-dave-hermes.nix
    ./ssh-tpm-agent.nix
    ./etc-hosts.nix
    ./nix-development.nix
    ./dns.nix
    ./nix.nix
    ./nix-parallel-downloads.nix
    # ./hyprspace
    ./nrb
    ./clan-unlock
    ./nix-caches.nix
    # niri compositor + noctalia shell are vendored from spaces (upstream moved
    # to COSMIC in 0434912e); ./niri-spaces/desktop-profile.nix re-creates the
    # desktop wiring spaces.nix used to do and keeps cosmic off. Host-local
    # additions layer on the /etc/niri/config-laptop.kdl wrapper (see
    # ./niri-monitor-binds.nix).
    ./niri-spaces/desktop-profile.nix
    ./niri-monitor-binds.nix
    ./niri-terminal-cwd.nix
    ./niri-float-rules.nix
    ./niri-layout-tweaks.nix
    ./niri-output-extras.nix
    ./greetd.nix
    ./pi-agent.nix
    # herdr wrapped with the community herdr-jj plugin (jj workspaces).
    ./herdr-jj.nix
    ./afk.nix
    # Same p0 models.yml for spaces' bare omp.
    ./omp-p0.nix
    # Bearer token for the fleet inference endpoint; `p0-api-key` hands it
    # to every harness's models.yml.
    ./inference-api-key.nix
    # TeamClaude gateway key (anthropic provider override in models.yml):
    # disabled with the provider block, see ./omp-common.nix.
    # ./teamclaude-api-key.nix
    ./amd-pstate-resume-fix.nix
    ./omr.nix
    ./ntop.nix
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
    ./nix-lazy.nix
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
    ./deluge.nix
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
