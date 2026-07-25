{
  description = "bam inference VM guest (standalone; will move to its own repo)";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = {nixpkgs, disko, ...}: let
    modules = [
      disko.nixosModules.disko
      ./disko.nix
      ./configuration.nix
    ];
  in {
    nixosConfigurations.inference = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      inherit modules;
    };
    # Identical system, but with the disko device pointing at the 1TB NVMe
    # by the PCI path bam sees while it is temporarily host-bound. Used ONLY
    # to build the format/mount script run on bam during install; the guest
    # itself mounts by partlabel, so the device path never matters at runtime.
    nixosConfigurations.inference-hostformat = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules =
        modules
        ++ [
          {
            disko.devices.disk.main.device =
              nixpkgs.lib.mkForce "/dev/disk/by-path/pci-0000:0a:00.0-nvme-1";
          }
        ];
    };
  };
}
