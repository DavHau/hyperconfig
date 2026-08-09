# Encrypted ZFS root, unlockable two ways, key held by clan.
#
#   clan-unlock <machine> <host>   from any clan machine (../clan-unlock)
#   screen + keyboard              prompt on the console, same passphrase
#
# The passphrase is a clan var with deploy = false: it never lands on the
# machine whose disk it protects. To read it: clan vars get <m> zfs-key/passphrase
{ config, lib, pkgs, ... }:
let
  dataset = "zroot/root";
  askKey = pkgs.writeShellApplication {
    name = "zfs-ask-key";
    runtimeInputs = [
      config.boot.zfs.package
      pkgs.systemd
    ];
    text = builtins.readFile ./ask-key.sh;
  };
in
{
  imports = [ ./wifi.nix ];

  # The stock prompt blocks the import service, which would leave the remote
  # path unable to finish the boot. ./ask-key.sh asks on the console instead,
  # re-arming on a timeout so either route wins.
  boot.zfs.requestEncryptionCredentials = false;

  boot.initrd.systemd.storePaths = [ askKey ];
  boot.initrd.systemd.services.zfs-key-prompt = {
    description = "Console passphrase prompt for ${dataset}";
    wantedBy = [ "initrd.target" ];
    after = [ "zfs-import-zroot.service" ];
    before = [ "sysroot.mount" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${lib.getExe askKey} ${dataset}";
    };
  };

  # Debug hatch. Physical access already owns the unencrypted initrd; it still
  # never yields the disk key.
  boot.initrd.systemd.emergencyAccess = true;

  boot.initrd.network.enable = true;
  boot.initrd.network.ssh = {
    enable = true;
    port = 2222;
    # Own key: the initrd lives unencrypted in the ESP, so this must not be
    # the host's real ssh identity. Generated below on first activation.
    hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
    # authorizedKeys defaults to users.users.root.openssh.authorizedKeys.keys,
    # which the clan admin role fills.
  };

  # The per-interface networks (40-enp6s0, 40-wlan0) already carry DHCP.
  boot.initrd.systemd.network.enable = true;

  # Read by append-initrd-secrets at bootloader install, which runs after the
  # activation scripts — so generating it here is enough, including on a fresh
  # install.
  system.activationScripts.initrdSshHostKey = ''
    if [ ! -f /etc/secrets/initrd/ssh_host_ed25519_key ]; then
      mkdir -p -m 0700 /etc/secrets/initrd
      ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" \
        -f /etc/secrets/initrd/ssh_host_ed25519_key
    fi
  '';

  clan.core.vars.generators.zfs-key = {
    files.passphrase = {
      secret = true;
      deploy = false;
    };
    runtimeInputs = [
      pkgs.coreutils
      pkgs.xkcdpass
    ];
    script = ''
      xkcdpass --numwords 6 --delimiter - --count 1 | tr -d "\n" > "$out"/passphrase
    '';
  };
}
