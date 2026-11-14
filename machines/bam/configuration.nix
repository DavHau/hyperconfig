{config, ...}: {
  imports = [
    ../../modules/nixos/common.nix
    ../../modules/nixos/common-tools.nix
    ../../modules/nixos/sbox.nix
    ./disko-xfs.nix
    ./zfs.nix
    ./nextcloud.nix
    ./vikunja.nix
    ./inference-host.nix
    ./inference-net.nix
    ./inference-vm.nix
    # storagebox-sync imports storagebox.nix (the mount, the shared password
    # var and the host-key pin), so it is the only line needed here.
    ../../modules/nixos/storagebox-sync.nix
    ../../modules/nixos/vault-nfs-server.nix
    ./scan-trigger.nix
    # RAM LEDs off (dramMode defaults to off).
    ../../modules/nixos/rgb-off.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  boot.binfmt.emulatedSystems = ["aarch64-linux"];

  # Must not change: the vault pool's labels carry this hostId, and a mismatch
  # makes every import need -f (see ./zfs.nix).
  networking.hostId = "b411ca35";

  nix.settings.max-jobs = 1;
  nix.settings.sandbox = "relaxed";

  users.users.dave.openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys;

  services.jackett.enable = true;
  services.jackett.openFirewall = true;

  # Firmware this box loads (../../modules/nixos/firmware-only.nix), from
  # its kernel log, PCI/USB ids and the drivers' firmware names: the
  # Raphael iGPU (amdgpu: GC 10.3.6, PSP 13.0.5, SDMA 5.2.6, VCN 3.1.2,
  # DCN 3.1.5), the RTL8126A (r8169, XID 64a), the WCN7850 wifi (ath12k
  # hw2.0) and its Bluetooth half (0489:e10a, btusb as QCA ROME 0x190200:
  # rampatch/nvm_usb_00190200 in earlier boots' logs; the qca/hmt files
  # in case a newer kernel identifies it as WCN7850). The RTX 5090 is
  # vfio'd to the inference guest, which brings its own firmware.
  hyper.firmwareOnly = [
    "amdgpu/gc_10_3_6_*"
    "amdgpu/psp_13_0_5_*"
    "amdgpu/sdma_5_2_6*"
    "amdgpu/vcn_3_1_2*"
    "amdgpu/dcn_3_1_5_*"
    "rtl_nic/rtl8126a-*"
    "ath12k/WCN7850/hw2.0"
    "qca/hmt*"
    "qca/rampatch_usb_00190200.bin"
    "qca/nvm_usb_00190200*"
  ];
  hardware.cpu.amd.updateMicrocode = true;
}
