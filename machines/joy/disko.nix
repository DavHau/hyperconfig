{ pkgs, lib, ... }:
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/disk/by-id/some-disk-id";
      imageSize = "16G";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          luks = {
            size = "100%";
            content = {
              type = "luks";
              name = "cryptusb";
              # passwordFile is only used during image creation (not propagated to boot config),
              # so the booted system will prompt interactively for the LUKS passphrase.
              # Provide the password file at build time via: --pre-format-files ./secret.key /tmp/secret.key
              passwordFile = "/tmp/secret.key";
              settings.allowDiscards = true;
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
