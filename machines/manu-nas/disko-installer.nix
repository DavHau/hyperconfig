{extendModules, inputs, lib, ...}: let
  extendedNixos = extendModules {
    modules = [
      (inputs.nixos-images + /nix/kexec-installer/module.nix)
    ];
  };
in {
  system.build.anywhereInstaller =
    lib.mkForce extendedNixos.config.system.build.kexecTarball;
}
