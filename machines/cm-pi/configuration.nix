{config, lib, inputs, modulesPath, pkgs, ...}: {
  imports = [
    (inputs.nixos-hardware + "/starfive/visionfive/v2")
    ../../modules/nixos/common.nix
    ../../modules/nixos/common-tools.nix
    ../../modules/nixos/sbox.nix
    ../../modules/nixos/riscv64.nix
    ./home-assistant.nix
    # hermes as HA's conversation agent (../../modules/nixos/voice-gateway).
    ../../modules/nixos/voice-gateway/cm-pi.nix
    # ./odoo.nix
  ];

  # TODO: remove this once fixed in nixpkgs
  programs.fish.enable = lib.mkForce false;
  documentation.nixos.enable = false;

  nixpkgs.hostPlatform = "riscv64-linux";
  clan.core.networking.targetHost= "root@cm-pi.local";
  # clan.core.networking.buildHost= "root@cm-pi.local";

  # The VisionFive 2 loads no linux-firmware file (none in five boots'
  # kernel logs; its only USB device is the Zigbee dongle, cdc_acm): the
  # board firmware lives in SPI flash (nixos-hardware's firmware.nix).
  # ../../modules/nixos/firmware-only.nix
  hyper.firmwareOnly = [ ];

  system.stateVersion = "25.05";
  systemd.tpm2.enable = false;
  boot.initrd.systemd.tpm2.enable = false;

  nixpkgs.pkgs = import inputs.nixpkgs-riscv {
    system = "x86_64-linux";
    crossSystem = "riscv64-linux";
    # config.contentAddressedByDefault = true;
  };

  # The overlay applies to every package set, native ones included: the
  # changes below only touch the cross (x86_64 -> riscv64) set, so the
  # native packages stay the cached ones.
  nixpkgs.overlays = [(self: super: let
    cross = super.stdenv.buildPlatform.config != super.stdenv.hostPlatform.config;
    ifCross = pkg: f: if cross then f pkg else pkg;
  in {
    nixos-facter = self.hello;
    # screen = self.hello;

    # Build-only tools from the build platform (cached on cache.nixos.org)
    # instead of cross-built from source:
    # - bpftool (BPF skeletons at build time): the spliced default needs a
    #   from-source binutils with all targets (~1 build-hour).
    # - Alloy's web UI is arch-independent JS; cross-building it builds
    #   nodejs for riscv64.
    # importd (machinectl pull/import, unused) pulls in gnupg; sysupdate
    # (off) needs importd, so it goes too (meson couples them).
    systemd = ifCross super.systemd (p: p.override {
      bpftools = self.pkgsBuildBuild.bpftools;
      withImportd = false;
      withSysupdate = false;
    });
    networkmanager = ifCross super.networkmanager (p: p.override {
      bpftools = self.pkgsBuildBuild.bpftools;
    });
    grafana-alloy = ifCross super.grafana-alloy (p: p.overrideAttrs {
      frontend = self.pkgsBuildBuild.grafana-alloy.frontend;
    });

    # pynacl and pycares propagate their build-platform cffi (x86_64
    # python3, ~360 MiB) into the runtime closure; only their own builds
    # need it. The riscv64 cffi stays a runtime dependency.
    pythonPackagesExtensions = super.pythonPackagesExtensions ++ lib.optional cross
      (pyself: pysuper: lib.genAttrs [ "pynacl" "pycares" ] (name:
        pysuper.${name}.overridePythonAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ (old.propagatedNativeBuildInputs or [ ]);
          propagatedNativeBuildInputs = [ ];
        })));
  })];

  # One systemd: link these against the module's patched systemd.package
  # instead of building the unpatched pkgs.systemd as well.
  # nixpkgs 2026-11 renamed dbus-broker's input systemd -> systemdLibs.
  services.dbus.brokerPackage = pkgs.dbus-broker.override (
    if lib.functionArgs pkgs.dbus-broker.override ? systemdLibs then
      { systemdLibs = config.systemd.package; }
    else
      { systemd = config.systemd.package; }
  );
  services.zram-generator.package = pkgs.zram-generator.override { systemd = config.systemd.package; };

  # Headless: no docs, man pages or default packages (perl, strace);
  # less to cross-compile.
  documentation.enable = false;
  documentation.man.enable = false;
  environment.defaultPackages = [ ];
  environment.stub-ld.enable = false;
  system.tools.nixos-option.enable = false;
  system.tools.nixos-generate-config.enable = false;

  # clan.core.networking.targetHost= "root@[${config.clan.core.facts.services.zerotier.public.zerotier-ip.value}]";

  image.modules.starfive2 = ({config, ...}: {
    imports = [
      "${inputs.nixos-hardware}/starfive/visionfive/v2/sd-image.nix"
      # (modulesPath + "/installer/sd-card/sd-image.nix")
    ];
    disabledModules = [
      ./hardware-configuration.nix
      "${modulesPath}/profiles/base.nix"
    ];
    # sdImage.compressImage = false;
    # system.build.image = config.system.build.sdImage;
  });
}
