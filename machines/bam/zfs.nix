# The `vault` data pool: 4x 4TB SAS HDD in raidz2, natively encrypted.
#
# Root is XFS (./disko-xfs.nix), so nothing here touches the initrd - the pool
# is imported by the normal (stage 2) zfs-import-vault.service.
#
# Two boot-blocking hazards this config deliberately avoids:
#
#  1. The stock import service prompts for a passphrase via
#     systemd-ask-password with boot.zfs.passwordTimeout = 0 ("wait forever")
#     and 3 retries. On a headless host that hangs the boot indefinitely -
#     which is exactly what the removed machines/bam/zfs.nix did (it left
#     requestEncryptionCredentials at its default of true against a pool
#     created with keylocation=prompt). The key is a raw keyfile instead,
#     placed by clan vars, and the prompt is disabled outright.
#
#  2. nixos/modules/tasks/filesystems/zfs.nix loops `poolReady` up to 60 times
#     and only accepts state ONLINE, so a permanently DEGRADED pool burns the
#     full 60s before its fallback import. The loop is hardcoded. What keeps
#     that off the critical path is `nofail` on every mount (see fileSystems
#     below): local-fs.target only *wants* those mounts and is not ordered
#     after them, so the boot proceeds while the import is still grinding.
#
#     The import service is additionally wantedBy zfs.target. nixpkgs only
#     wires it into zfs-import.target when no filesystem is `noauto`, and an
#     earlier revision of this file used noauto + x-systemd.automount - which
#     left the unit referenced solely by .mount units that were themselves
#     inactive until triggered, so after a reboot the pool stayed unimported
#     ("cannot open 'vault': no such pool"). The explicit wantedBy makes the
#     trigger independent of that heuristic.
{ config, ... }:
{
  boot.supportedFilesystems.zfs = true;

  boot.zfs.extraPools = [ "vault" ];

  # Import on every boot regardless of the noauto heuristic above. Wants= is a
  # weak dep: nothing waits for it to finish.
  systemd.services.zfs-import-vault.wantedBy = [ "zfs.target" ];

  # See hazard 1 above: the danger is the *interactive* prompt, not key loading
  # itself. Setting this to `false` disables the whole load-key step, which left
  # the pool imported but every mount failing with "encryption key not loaded".
  # Passing the dataset list instead keeps the loader while never prompting:
  # keylocation is a file, so the `* )` branch of the import script runs
  # `zfs load-key` directly and systemd-ask-password is never reached.
  boot.zfs.requestEncryptionCredentials = [ "vault" ];

  # The host is not this machine's owner: machines/bam/inference-host.nix pins
  # 108 of 125 GiB into 1G hugepages for the inference VM and confines
  # system.slice/user.slice to AllowedCPUs = "0,16" - one physical core plus
  # its SMT sibling. ZFS runs entirely inside that budget, so the ARC gets 4
  # GiB of the ~10 GiB the host actually has. (The pre-removal config asked
  # for a 64 GiB ARC, which this host cannot back.)
  boot.kernelParams = [
    "zfs.zfs_arc_max=4294967296" # 4 GiB
    "zfs.zfs_arc_min=1073741824" # 1 GiB
  ];

  # Raw 32-byte key. deploy = true (unlike the zfs-remote-unlock generator,
  # which withholds the root passphrase from its own machine): an unattended
  # mount needs the key present. This is a data pool on an unencrypted XFS
  # root, so the threat model is a disk leaving the building - theft, RMA,
  # resale - not an attacker on the running host.
  clan.core.vars.generators.vault-key = {
    files.key = {
      secret = true;
      deploy = true;
      mode = "0400";
    };
    runtimeInputs = [ config.boot.zfs.package ];
    script = ''
      dd if=/dev/urandom bs=32 count=1 of="$out"/key status=none
    '';
  };

  # Mounted at boot, but never gating it. systemd.mount(5): with `nofail` a
  # mount is "only wanted, not required, by local-fs.target" and "is not
  # ordered before" it, so "the boot will continue without waiting for the
  # mount unit and regardless whether the mount point can be mounted
  # successfully". That is exactly the requirement: the datasets come up on
  # every boot, services can depend on them, and a slow degraded import cannot
  # hold the boot.
  #
  # Deliberately NOT `noauto` + x-systemd.automount: noauto keeps the mount out
  # of local-fs.target entirely, so nothing is mounted until something touches
  # the path - the pool would not be up at boot, and a unit that merely reads
  # /vault/... at start would race the first trigger.
  #
  # Services that need a dataset should declare RequiresMountsFor=/vault/<ds>
  # (systemd.unit(5)), which adds Requires= plus After= on that mount unit.
  fileSystems =
    let
      dataset = name: {
        device = "vault/${name}";
        fsType = "zfs";
        options = [ "nofail" ];
      };
    in
    {
      "/vault/parquet" = dataset "parquet";
      "/vault/photos" = dataset "photos";
      "/vault/media" = dataset "media";
      "/vault/misc" = dataset "misc";
    };

  # A scrub reads every allocated block and verifies checksums on that single
  # host core, competing with the VM's emulator threads (pinned to 8,24).
  # Monthly, at a fixed quiet hour rather than the default timer.
  services.zfs.autoScrub = {
    enable = true;
    interval = "monthly";
    pools = [ "vault" ];
  };

  services.zfs.trim.enable = false; # spinning rust
}
