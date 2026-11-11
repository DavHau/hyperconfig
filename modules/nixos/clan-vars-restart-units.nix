# `restartUnits` of clan vars, for clan's age backend.
#
# clan-core's age secret store (nixosModules/clanCore/vars/secret/age.nix)
# ignores `files.<f>.restartUnits`: only its sops backend passes it on (to
# sops-nix). With `vars.settings.age.externalStore` the encrypted file is
# not even in the system closure, so a new value of a var changes no unit
# and switch-to-configuration restarts nothing: a service that reads its
# secret only at start (LoadCredential=, a key read once) keeps the old
# value until someone restarts it by hand.
#
# This activation snippet runs right after clan's setupSecrets /
# setupUserSecrets have decrypted the vars, compares a salted hash of every
# deployed secret file that has restartUnits with the one recorded at the
# previous activation, and hands the units of the changed files to
# switch-to-configuration through /run/nixos/activation-restart-list (it
# restarts them like changed units: restartIfChanged/reloadIfChanged hold,
# an inactive unit gets started). The first activation after boot only
# records: every unit starts fresh then anyway. The hashes live in
# /run/clan-vars-restart-units (root, 0700, salted per boot), never on
# disk.
#
# nixpkgs deprecated the activation-restart-list in 26.05 ("will be removed
# in 26.11"). The build check below fails the system build once the
# switch-to-configuration in use no longer knows the file, so that day
# this comes back as a build error instead of silently dropped restarts.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  generators = config.clan.core.vars.generators or { };
  ageStore = (config.clan.core.vars.settings.secretStore or null) == "age";
  # clan's age backend decrypts from activation scripts unless sysusers or
  # userborn is on; then it uses oneshot services at sysinit, which this
  # snippet cannot order after.
  useSystemdActivation =
    (options.systemd ? sysusers && config.systemd.sysusers.enable)
    || config.services.userborn.enable;

  knownUnits = lib.attrNames config.systemd.units;

  entries = lib.concatLists (
    lib.mapAttrsToList (
      genName: gen:
      lib.concatLists (
        lib.mapAttrsToList (
          fileName: file:
          lib.optional
            (
              file.secret
              && file.deploy
              && file.restartUnits != [ ]
              && lib.elem file.neededFor [
                "services"
                "users"
              ]
            )
            {
              id = "${genName}/${fileName}";
              inherit (file) path restartUnits;
              units = lib.filter (u: lib.elem u knownUnits) file.restartUnits;
              unknown = lib.filter (u: !lib.elem u knownUnits) file.restartUnits;
            }
        ) gen.files
      )
    ) generators
  );

  # One line per file: <state name> <path> <units...>. Names and paths
  # come from generator/file names, which clan restricts to [a-zA-Z0-9_.-].
  stateName = e: builtins.hashString "sha256" e.id;
  table = pkgs.writeText "clan-vars-restart-units" (
    lib.concatMapStrings (
      e: "${stateName e} ${e.path} ${lib.concatStringsSep " " e.units}\n"
    ) (lib.filter (e: e.units != [ ]) entries)
  );

  script = ''
    (
      set -u
      state=/run/clan-vars-restart-units
      dry=0
      [ "''${NIXOS_ACTION:-}" = dry-activate ] && dry=1
      fresh=0
      if [ ! -e "$state/.salt" ]; then
        # Nothing recorded yet (boot, or first switch with this module):
        # record only. A dry run records nothing, so it stops here.
        [ "$dry" = 1 ] && exit 0
        fresh=1
        rm -rf "$state"
        install -d -m 0700 "$state"
        head -c 32 /dev/urandom > "$state/.salt.tmp"
        chmod 0400 "$state/.salt.tmp"
        mv "$state/.salt.tmp" "$state/.salt"
      fi
      if [ "$dry" = 1 ]; then
        list=/run/nixos/dry-activation-restart-list
      else
        list=/run/nixos/activation-restart-list
      fi
      mkdir -p /run/nixos
      while read -r name path units; do
        if [ -e "$path" ]; then
          new=$(cat "$state/.salt" "$path" | sha256sum | cut -d' ' -f1)
        else
          new=absent
        fi
        old=$(cat "$state/$name" 2>/dev/null || echo none)
        if [ "$fresh" = 0 ] && [ "$old" != "$new" ] && [ "$new" != absent ]; then
          echo "clan vars: $path changed, restarting: $units" >&2
          for u in $units; do echo "$u" >> "$list"; done
        fi
        if [ "$dry" = 0 ]; then
          printf '%s\n' "$new" > "$state/$name"
        fi
      done < ${table}
    )
  '';

  hasSetup = name: config.system.activationScripts ? ${name};
in
{
  config = lib.mkIf (ageStore && entries != [ ]) {
    warnings =
      lib.optional useSystemdActivation
        "clan-vars-restart-units: clan decrypts age vars via systemd units here (sysusers/userborn); restartUnits are not honoured."
      ++ lib.concatMap (
        e:
        lib.optional (
          e.unknown != [ ]
        ) "clan var ${e.id}: restartUnits ${lib.concatStringsSep ", " e.unknown} name no unit of this system; ignored."
      ) entries;

    system.activationScripts.clanVarsRestartUnits = lib.mkIf (!useSystemdActivation) {
      deps = lib.filter hasSetup [
        "setupSecrets"
        "setupUserSecrets"
      ];
      text = script;
      supportsDryActivation = true;
    };

    # Fail the build, not the restarts, once nixpkgs drops the interface.
    system.checks = [
      (pkgs.runCommand "clan-vars-restart-units-check" { } ''
        if ! grep -rqa /run/nixos/activation-restart-list ${pkgs.switch-to-configuration-ng}; then
          echo "switch-to-configuration no longer reads /run/nixos/activation-restart-list:" >&2
          echo "clan vars' restartUnits (modules/nixos/clan-vars-restart-units.nix) would be ignored." >&2
          exit 1
        fi
        touch $out
      '')
    ];
  };
}
