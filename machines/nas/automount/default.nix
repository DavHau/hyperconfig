# nas' encrypted datasets pool11/enc and rpool/enc: unlocked at boot via
# clevis/tang, and nothing writes under them unless they are mounted
# (./enc-guard.nix says how; ./snapshots.nix keeps snapshots of them).
#
# Manual fallback (tang down, JWE missing, or automount failed):
#   ssh -t root@nas.d enter-password
# It prompts once for the passphrase, loads it into every locked root and
# restarts automount (by hand: `zfs load-key pool11/enc && zfs load-key
# rpool/enc && systemctl restart automount`). The passphrase is the clan var
# below (`clan vars get nas zfs-key/passphrase` on Dave's machine).
# automount then finds the keys loaded, mounts and checks everything, and
# starts the guarded services (it pulls them in). Check with
#   ssh nas.d 'systemctl status automount; systemctl --failed'
{ config, lib, pkgs, ... }:
let
  # The tang on the ESPHome plug; its public vars come from
  # modules/nixos/esphome-secrets.nix.
  vars = import ../../../modules/nixos/zfs-remote-unlock/vars.nix { inherit pkgs; };
  tang = rec {
    url = "http://192.168.20.31:7654";
    advFile = ../../../vars/shared/esphome-casa/tang_adv/value;
    thp = builtins.readFile ../../../vars/shared/esphome-casa/tang_thp/value;
    validation = {
      inherit url thp;
      adv = builtins.readFile advFile;
    };
  };
in
{
  imports = [
    ./enc-guard.nix
    ./snapshots.nix
  ];

  # The ZFS passphrase of pool11/enc and rpool/enc, kept in the clan vars
  # store only (deploy = false): manual recovery, and the input of the
  # clevis/tang binding below. Same var as som's (zfs-key/passphrase, from
  # modules/nixos/zfs-remote-unlock/vars.nix), but never generated: the
  # roots' passphrase exists, it is set by hand (copied byte for byte from
  # the old zfs-passphrase/passphrase, no trailing newline):
  #     clan vars get nas zfs-passphrase/passphrase | clan vars set nas zfs-key/passphrase
  # Changing the passphrase means changing it on BOTH roots
  # (`zfs change-key pool11/enc`, `zfs change-key rpool/enc`; they share
  # it), then setting it here and re-binding:
  #     clan vars generate nas --generator zfs-tang --regenerate --no-sandbox
  # (run it explicitly: `validation` does not track the passphrase). Until
  # the JWE matches again, the daily enc-unlock-selftest fails, and so would
  # the next boot's unlock.
  clan.core.vars.generators.zfs-key = vars.zfs-key {
    generate = false;
    refusal = "nas zfs-key must be imported from zfs-passphrase, never generated";
  };

  # The passphrase's former var, before nas took som's names. Unused; kept
  # declared (with its value in the secrets repo) for a rollback to the
  # previous generation. Drop it once zfs-key has proven itself.
  clan.core.vars.generators.zfs-passphrase = {
    prompts.passphrase = {
      type = "hidden";
      persist = true;
      description = "ZFS passphrase of pool11/enc and rpool/enc (old name, see zfs-key)";
    };
    files.passphrase.deploy = false;
  };

  # The passphrase as a clevis JWE bound to tang (./tang-bind.nix), at
  # zfs-tang/zfs-key.jwe like som's: no prompt, no network, so infra-space
  # generates it (bwrap is unavailable there, hence --no-sandbox; it is our
  # own script):
  #     clan vars generate nas --generator zfs-tang --no-sandbox
  # That run writes two repos, and both must be committed and pushed
  # before any deploy (until then every `clan machines update`, of any
  # machine, tries to generate it and fails):
  #   - hyperconfig: vars/per-machine/nas/zfs-tang/.validation-hash
  #     (public; tells clan the binding matches `validation` below);
  #   - the clan-secrets repo: clan-vars/per-machine/nas/zfs-tang/
  #     zfs-key.jwe/zfs-key.jwe.age (the JWE, age-encrypted to nas and the
  #     admins).
  clan.core.vars.generators.zfs-tang = import ./tang-bind.nix {
    inherit pkgs;
    inherit (tang) url advFile thp validation;
  };

  encGuard = {
    roots = [
      "pool11/enc"
      "rpool/enc"
    ];
    # What must be mounted before anything may write below it.
    mounts = {
      "/pool11/enc" = "pool11/enc";
      "/pool11/enc/data" = "pool11/enc/data";
      "/rpool/enc" = "rpool/enc";
    };
    jweFile = config.clan.core.vars.generators.zfs-tang.files."zfs-key.jwe".path;
    docs = "machines/nas/automount/default.nix in hyperconfig";
    # The borg repos below /pool11/enc (clan borgbackup server role,
    # dave-backup) are gated by enc-guard.nix itself.
    # ../sync-from-manu.nix registers its own.
    services = {
      filebrowser-manu = [ config.users.users.manu.home ];
      filebrowser-roman = [ config.users.users.roman.home ];
    };
  };

  # The manual fallback from the header: one prompt for all locked roots.
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "enter-password";
      runtimeInputs = [
        pkgs.zfs
        pkgs.systemd
      ];
      text = ''
        for ds in ${lib.escapeShellArgs config.encGuard.roots}; do
          if [ "$(zfs get -H -o value keystatus "$ds")" = available ]; then
            echo "$ds: key already loaded"
            continue
          fi
          if [ -z "''${passwd+x}" ]; then
            read -rsp "ZFS passphrase (${toString config.encGuard.roots}): " passwd
            echo
          fi
          printf '%s\n' "$passwd" | zfs load-key "$ds"
          echo "$ds: key loaded"
        done
        systemctl restart automount
      '';
    })
  ];

  # Homes on pool11/enc/data: activation must never mkdir them into the
  # bare mountpoint while the dataset is locked. They exist in the dataset.
  users.users = lib.genAttrs [
    "backup"
    "david"
    "guest"
    "manu"
    "roman"
    "stefan"
  ] (_: { createHome = false; });
}
