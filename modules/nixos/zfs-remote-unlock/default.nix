# Encrypted ZFS root, unlockable three ways, key held by clan.
#
#   Tang peers                     automatic, when tang.servers is set
#   clan-unlock <machine> <host>   from any clan machine (../clan-unlock)
#   screen + keyboard              prompt on the console, same passphrase
#
# The passphrase is a clan var with deploy = false: it never lands on the
# machine whose disk it protects. To read it: clan vars get <m> zfs-key/passphrase
#
# Tang: the initrd carries the passphrase encrypted to the servers' Tang keys
# (clevis, any one server suffices) and asks them over link-local
# (../tang-server.nix). Every server keeps its keys on its own encrypted root,
# so a set of stolen machines cannot unlock each other; after a full power
# cut the first one is unlocked by hand and the rest follow.
{ config, lib, pkgs, inputs, ... }:
let
  dataset = "zroot/root";
  tang = config.hyper.zfsRemoteUnlock.tang;
  useTang = tang.servers != [ ];
  jwePath = "/etc/clevis/zfs-key.jwe";

  servers = map (
    name:
    let
      server = inputs.self.nixosConfigurations.${name}.config;
    in
    {
      # The zone pins the link-local request to the initrd's LAN NIC.
      url = "http://[${server.hyper.tangServer.address}%25${tang.interface}]:7654";
      adv = server.clan.core.vars.generators.tang.files."adv.jws".value;
    }
  ) tang.servers;

  askKey = pkgs.writeShellApplication {
    name = "zfs-ask-key";
    runtimeInputs = [
      config.boot.zfs.package
      pkgs.systemd
    ]
    ++ lib.optional useTang config.boot.initrd.clevis.package;
    text = builtins.readFile ./ask-key.sh;
  };
in
{
  options.hyper.zfsRemoteUnlock.tang = {
    servers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "vit" ];
      description = "Machines running hyper.tangServer that may unlock this one; any one suffices.";
    };
    interface = lib.mkOption {
      type = lib.types.str;
      example = "enp6s0";
      description = "The initrd's LAN interface, on the servers' link.";
    };
  };

  config = lib.mkMerge [
    {
      # The stock prompt blocks the import service, which would leave the remote
      # path unable to finish the boot. ./ask-key.sh asks on the console instead,
      # re-arming on a timeout so every route wins.
      boot.zfs.requestEncryptionCredentials = false;

      boot.initrd.systemd.storePaths = [ askKey ];
      boot.initrd.systemd.services.zfs-key-prompt = {
        description = "Unlock ${dataset}: Tang, then console passphrase prompt";
        wantedBy = [ "initrd.target" ];
        after = [ "zfs-import-zroot.service" ];
        before = [ "sysroot.mount" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${lib.getExe askKey} ${dataset}${lib.optionalString useTang " ${jwePath}"}";
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

    (lib.mkIf useTang {
      # The passphrase, encrypted to the servers' advertised keys. Bound
      # offline against the advertisements in their public vars; a server
      # rekey changes the validation hash and so regenerates this.
      clan.core.vars.generators.zfs-tang = {
        dependencies = [ "zfs-key" ];
        # Useless without a server, yet a secret: anyone holding it who can
        # also reach a server on the LAN gets the passphrase. neededFor =
        # activation: clan uploads it before the switch and it persists, so
        # append-initrd-secrets finds it even on a `boot`-only switch, which
        # runs no activation (sops would only fill /run/secrets at boot).
        files."zfs-key.jwe".neededFor = "activation";
        validation.servers = builtins.toJSON servers;
        runtimeInputs = [ pkgs.clevis ];
        script = ''
          clevis encrypt sss ${
            lib.escapeShellArg (
              builtins.toJSON {
                t = 1;
                pins.tang = map (s: {
                  inherit (s) url;
                  adv = "${pkgs.writeText "tang-adv.jws" s.adv}";
                }) servers;
              }
            )
          } < "$in/zfs-key/passphrase" > "$out/zfs-key.jwe"
        '';
      };

      boot.initrd.secrets.${jwePath} =
        config.clan.core.vars.generators.zfs-tang.files."zfs-key.jwe".path;

      # Packs clevis, jose and curl into the initrd. No `devices`: ./ask-key.sh
      # does the decrypting, with retries the stock one-shot hook lacks.
      boot.initrd.clevis.enable = true;
    })
  ];
}
