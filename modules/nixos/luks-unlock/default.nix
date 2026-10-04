# Encrypted LUKS root, key held by clan, unlockable three ways:
#
#   Tang peers          automatic, with hyper.tangClient.servers
#   clan-unlock <m>     from any clan machine, over the initrd's ssh
#                       (../clan-unlock, ../initrd-ssh.nix, ./unlock.sh)
#   screen + keyboard   systemd-cryptsetup's prompt, the clan passphrase
#
# The passphrase is a clan var with deploy = false: it never lands on the
# machine whose disk it protects. To read it: clan vars get <m> luks-key/passphrase
# To make it the disk's passphrase (asks for the current one):
#   clan vars get <m> luks-key/passphrase | ssh root@<m> 'umask 077; cat > /run/luks-new'
#   ssh -t root@<m> luks-set-passphrase /run/luks-new
#
# Tang (../tang-client.nix): a dedicated random key, stored only
# clevis-encrypted to the servers, sits in its own keyslot. In the initrd
# ./agent.sh answers systemd-cryptsetup's passphrase request with it once a
# server replies; the console prompt stays usable meanwhile. Enrol the key
# once, and again after the servers change (a new binding brings a new key):
#   clan vars get <m> luks-key/passphrase | ssh root@<m> enroll-luks-tang-key
# LUKS2 keeps the volume key in the kernel keyring, out of root's reach, so
# both tools need an existing passphrase.
{ config, lib, pkgs, ... }:
let
  cfg = config.hyper.luksUnlock;
  tang = config.hyper.tangClient;
  device = config.boot.initrd.luks.devices.${cfg.name}.device;
  jwePath = "/etc/clevis/luks-key.jwe";
  jweFile = config.clan.core.vars.generators.luks-tang.files."key.jwe".path;
  replyPassword = "${config.boot.initrd.systemd.package}/lib/systemd/systemd-reply-password";

  agent = pkgs.writeShellApplication {
    name = "luks-tang-agent";
    runtimeInputs = [
      config.boot.initrd.clevis.package
      pkgs.gnused
      pkgs.gnugrep
      pkgs.coreutils
    ];
    runtimeEnv.REPLY_PASSWORD = replyPassword;
    text = builtins.readFile ./agent.sh;
  };

  # `clan-unlock <m>` pipes the passphrase into this over the initrd's ssh.
  unlock = pkgs.writeShellApplication {
    name = "unlock";
    runtimeInputs = [
      pkgs.gnused
      pkgs.gnugrep
      pkgs.coreutils
    ];
    runtimeEnv = {
      REPLY_PASSWORD = replyPassword;
      LUKS_DEVICE = device;
    };
    text = builtins.readFile ./unlock.sh;
  };

  # Replaces the keyslot of the passphrase typed at the prompt with the one
  # in <file>, then shreds <file>.
  setPassphrase = pkgs.writeShellApplication {
    name = "luks-set-passphrase";
    runtimeInputs = [
      pkgs.cryptsetup
      pkgs.coreutils
    ];
    text = ''
      new=$1
      trap 'shred -u "$new"' EXIT
      echo "Current passphrase of ${device}:"
      cryptsetup luksChangeKey ${device} "$new"
      cryptsetup open --test-passphrase --key-file "$new" ${device}
      echo "done: the clan passphrase opens ${device}"
    '';
  };

  # Adds the Tang key to a new keyslot, authorised by an existing passphrase
  # on stdin (or the prompt, from a terminal).
  enroll = pkgs.writeShellApplication {
    name = "enroll-luks-tang-key";
    runtimeInputs = [
      pkgs.clevis
      pkgs.cryptsetup
      pkgs.coreutils
    ];
    text = ''
      umask 077
      key=$(mktemp -p /run)
      trap 'shred -u "$key"' EXIT
      clevis decrypt < ${jweFile} > "$key"
      if cryptsetup open --test-passphrase --key-file "$key" ${device} 2>/dev/null; then
        echo "already enrolled"
        exit 0
      fi
      if [ -t 0 ]; then
        cryptsetup luksAddKey ${device} "$key"
      else
        cryptsetup luksAddKey --key-file=- ${device} "$key"
      fi
      cryptsetup open --test-passphrase --key-file "$key" ${device}
      echo "enrolled: the Tang key opens ${device}"
    '';
  };
in
{
  imports = [
    ../tang-client.nix
    ../unlock-target.nix
  ];

  options.hyper.luksUnlock.name = lib.mkOption {
    type = lib.types.str;
    example = "cryptroot";
    description = "boot.initrd.luks.devices entry holding the root.";
  };

  config = lib.mkMerge [
    {
      clan.core.vars.generators.luks-key = {
        # Never installed on the machine whose disk it protects.
        files.passphrase.deploy = false;
        runtimeInputs = [
          pkgs.coreutils
          pkgs.xkcdpass
        ];
        # 4 words (~52 bits) suffice behind LUKS2's argon2id, a memory-hard
        # ~2s per guess; ZFS's PBKDF2 is why zfs-key uses 6.
        script = ''
          xkcdpass --numwords 4 --delimiter - --count 1 | tr -d "\n" > "$out"/passphrase
        '';
      };

      environment.systemPackages = [ setPassphrase ];

      # On the initrd's PATH for the ssh recovery path.
      boot.initrd.systemd.storePaths = [
        unlock
        replyPassword
      ];
      boot.initrd.systemd.extraBin.unlock = lib.getExe unlock;
      hyper.unlockTarget.passphraseVar = "luks-key/passphrase";
    }

    (lib.mkIf tang.enable {
      clan.core.vars.generators.luks-tang = {
        # The key exists only inside this; enroll-luks-tang-key gets it back
        # through Tang. neededFor = activation: uploaded before the switch
        # and persistent, so append-initrd-secrets finds it on a `boot`-only
        # switch too.
        files."key.jwe".neededFor = "activation";
        validation.servers = tang.validation;
        runtimeInputs = [
          pkgs.clevis
          pkgs.openssl
          pkgs.coreutils
        ];
        # No newline: the agent passes the key as a passphrase, and $(...)
        # would strip one the keyslot was enrolled with.
        script = ''
          openssl rand -hex 32 | tr -d '\n' |
            clevis encrypt sss ${lib.escapeShellArg tang.clevisPolicy} > "$out/key.jwe"
        '';
      };

      boot.initrd.secrets.${jwePath} = jweFile;

      environment.systemPackages = [ enroll ];

      boot.initrd.systemd.storePaths = [
        agent
        replyPassword
      ];
      boot.initrd.systemd.services.luks-tang-agent = {
        description = "Answer ${cfg.name}'s passphrase request via Tang";
        wantedBy = [ "initrd.target" ];
        before = [
          "initrd-switch-root.target"
          "shutdown.target"
        ];
        conflicts = [
          "initrd-switch-root.target"
          "shutdown.target"
        ];
        after = [ "initrd-nixos-copy-secrets.service" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "simple";
          ExecStart = "${lib.getExe agent} ${cfg.name} ${device} ${jwePath}";
        };
      };
    })
  ];
}
