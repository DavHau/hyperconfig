# Encrypted ZFS root, unlockable three ways, key held by clan.
#
#   Tang peers                     automatic, with hyper.tangClient.servers
#   clan-unlock <machine>          from any clan machine (../clan-unlock)
#   screen + keyboard              prompt on the console, same passphrase
#
# The passphrase is a clan var with deploy = false: it never lands on the
# machine whose disk it protects. To read it: clan vars get <m> zfs-key/passphrase
#
# Tang (../tang-client.nix): the initrd carries the passphrase encrypted to
# the servers' keys; ./ask-key.sh asks them before and between prompts.
{ config, lib, pkgs, ... }:
let
  dataset = "zroot/root";
  tang = config.hyper.tangClient;
  jwePath = "/etc/clevis/zfs-key.jwe";

  askKey = pkgs.writeShellApplication {
    name = "zfs-ask-key";
    runtimeInputs = [
      config.boot.zfs.package
      pkgs.systemd
    ]
    ++ lib.optional tang.enable config.boot.initrd.clevis.package;
    text = builtins.readFile ./ask-key.sh;
  };

  # `clan-unlock som` pipes the passphrase into this over the initrd's ssh.
  # Loading the key ends ./ask-key.sh's loop within one prompt timeout;
  # restarting sysroot.mount does not wait for that.
  unlock = pkgs.writeShellApplication {
    name = "unlock";
    runtimeInputs = [
      config.boot.zfs.package
      pkgs.systemd
    ];
    text = ''
      zfs load-key -L file:///dev/stdin ${dataset}
      systemctl restart sysroot.mount
      systemctl default || true
    '';
  };
in
{
  imports = [
    ../tang-client.nix
    ../unlock-target.nix
  ];

  config = lib.mkMerge [
    {
      # The stock prompt blocks the import service, which would leave the remote
      # path unable to finish the boot. ./ask-key.sh asks on the console instead,
      # re-arming on a timeout so every route wins.
      boot.zfs.requestEncryptionCredentials = false;

      boot.initrd.systemd.storePaths = [
        askKey
        unlock
      ];
      boot.initrd.systemd.extraBin.unlock = lib.getExe unlock;
      hyper.unlockTarget.passphraseVar = "zfs-key/passphrase";

      boot.initrd.systemd.services.zfs-key-prompt = {
        description = "Unlock ${dataset}: Tang, then console passphrase prompt";
        wantedBy = [ "initrd.target" ];
        after = [ "zfs-import-zroot.service" ];
        before = [ "sysroot.mount" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${lib.getExe askKey} ${dataset}${lib.optionalString tang.enable " ${jwePath}"}";
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
        # which the clan sshd instance's authorizedKeys fill.
      };

      # The wired interface's 40-<iface> network (nixos-facter) already carries DHCP.
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
          # Never installed on the machine whose disk it protects.
          deploy = false;
          # ... but `clan machines install` must hand it to disko before it can
          # create the encrypted dataset. This phase uploads it to the *installer*
          # as /run/partitioning-secrets/zfs-key/passphrase (nixos-anywhere
          # --disk-encryption-keys) and nowhere else. Only the partitioning phase
          # consults neededFor, so deploy = false still holds for the target.
          neededFor = "partitioning";
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

    (lib.mkIf tang.enable {
      clan.core.vars.generators.zfs-tang = {
        dependencies = [ "zfs-key" ];
        # Useless without a server, yet a secret: anyone holding it who can
        # also reach a server on the LAN gets the passphrase. neededFor =
        # activation: clan uploads it before the switch and it persists, so
        # append-initrd-secrets finds it even on a `boot`-only switch, which
        # runs no activation (sops would only fill /run/secrets at boot).
        files."zfs-key.jwe".neededFor = "activation";
        validation.servers = tang.validation;
        runtimeInputs = [ pkgs.clevis ];
        script = ''
          clevis encrypt sss ${lib.escapeShellArg tang.clevisPolicy} \
            < "$in/zfs-key/passphrase" > "$out/zfs-key.jwe"
        '';
      };

      boot.initrd.secrets.${jwePath} =
        config.clan.core.vars.generators.zfs-tang.files."zfs-key.jwe".path;
    })
  ];
}
