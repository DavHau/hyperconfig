# Only the linux-firmware files a machine loads, instead of the whole
# ~850 MiB redistributable set that hardware.enableAllHardware
# (./all-hardware.nix) pulls in through enableRedistributableFirmware.
#
# A machine opts in with `hyper.firmwareOnly = [ <globs> ]`, globs relative
# to linux-firmware's lib/firmware (bash globstar: `**` crosses
# directories). `[ ]` means no firmware file at all. Unset (null) keeps the
# full set: machines with hotplugged or unobserved hardware (laptops, the
# installer, offline machines) stay on it.
#
# Each list is what the machine's kernel log, its PCI/USB ids and the
# drivers' firmware names showed it loads; a glob takes the whole family of
# a chip (every revision linux-firmware ships for it), so a driver that
# picks a newer file name after a kernel bump still finds it. A glob that
# matches nothing fails the build, so an upstream rename shows here and not
# at the next boot.
#
# Opting in turns enableRedistributableFirmware off, which also drops the
# CPU microcode default that follows it (nixpkgs' facter and nixos-hardware
# set updateMicrocode = mkDefault enableRedistributableFirmware): bare-metal
# machines set hardware.cpu.<vendor>.updateMicrocode = true themselves.
# The wireless regulatory database stays (cfg80211 asks for it everywhere).
{ config, lib, pkgs, ... }:
let
  globs = config.hyper.firmwareOnly;
  linuxFirmware = pkgs.linux-firmware;
  only = pkgs.runCommand "linux-firmware-only-${linuxFirmware.version}" {
    inherit globs;
    __structuredAttrs = true;
    # The result is compressed by hardware.firmwareCompression like any
    # other hardware.firmware entry.
    passthru = { inherit (linuxFirmware) version; };
  } ''
    shopt -s globstar nullglob
    src=${linuxFirmware}/lib/firmware
    mkdir -p "$out/lib/firmware"
    cd "$src"
    for glob in "''${globs[@]}"; do
      matches=( $glob )
      if [ ''${#matches[@]} -eq 0 ]; then
        echo "hyper.firmwareOnly: '$glob' matches nothing in $src" >&2
        exit 1
      fi
      for f in "''${matches[@]}"; do
        # -L: a symlink (e.g. intel/ibt-0041-0041.ddc -> ibt-0040-0041.ddc)
        # becomes the file it points to, so no link dangles.
        cp -rL --parents --no-preserve=mode -- "$f" "$out/lib/firmware/"
      done
    done
  '';
in
{
  options.hyper.firmwareOnly = lib.mkOption {
    type = lib.types.nullOr (lib.types.listOf lib.types.str);
    default = null;
    example = [ "amdgpu/gc_10_3_6*" "rtl_nic/rtl8125b-*" ];
    description = ''
      linux-firmware files (globs relative to lib/firmware) this machine
      needs; replaces enableRedistributableFirmware. null keeps the full set.
    '';
  };

  config = lib.mkIf (globs != null) {
    hardware.enableRedistributableFirmware = lib.mkForce false;
    hardware.wirelessRegulatoryDatabase = true;
    hardware.firmware = lib.optional (globs != [ ]) only;
  };
}
