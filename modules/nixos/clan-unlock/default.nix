# clan-unlock <machine>: feed a machine waiting for its disk passphrase,
# over ssh into its initrd. Where it is and which passphrase it wants come
# from the machine's own hyper.unlockTarget (../unlock-target.nix), baked
# in at build time, and so are the host keys: the jump host's clan-managed
# key under its yggdrasil address, the initrd's where clan holds it
# (../initrd-ssh.nix). An initrd key clan does not hold is trusted on first
# use.
{ lib, pkgs, inputs, ... }:
let
  # Machines with an unlockTarget. Listed, not discovered: discovering
  # would evaluate every machine in the flake for each build here.
  machines = [
    "som"
    "vit"
  ];

  configOf = name: inputs.self.nixosConfigurations.${name}.config;
  generatorsOf = name: (configOf name).clan.core.vars.generators;
  yggAddress = name: (generatorsOf name).yggdrasil.files.address.value;
  hostKey = name: (generatorsOf name).openssh.files."ssh.id_ed25519.pub".value;

  viaOf = name: (configOf name).hyper.unlockTarget.via;
  knownHosts = pkgs.writeText "clan-unlock-known-hosts" (
    lib.concatMapStrings (
      name:
      "${yggAddress (viaOf name)} ${hostKey (viaOf name)}\n"
      + lib.optionalString ((generatorsOf name) ? initrd-ssh) (
        "${name}-initrd ${(generatorsOf name).initrd-ssh.files."ssh_host_ed25519_key.pub".value}\n"
      )
    ) machines
  );

  targetCase =
    name:
    let
      target = (configOf name).hyper.unlockTarget;
    in
    ''
      ${name})
        jump="${yggAddress target.via}"
        dest="${target.address}%${(configOf target.via).hyper.unlockTarget.lanInterface}"
        var="${target.passphraseVar}"
        ;;
    '';
in
{
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "clan-unlock";
      runtimeInputs = [
        inputs.clan-core.packages.x86_64-linux.clan-cli
        pkgs.openssh
      ];
      runtimeEnv.KNOWN_HOSTS = knownHosts;
      text = ''
        target() {
          case "$1" in
            ${lib.concatMapStrings targetCase machines}
            *) return 1 ;;
          esac
        }
      ''
      + builtins.readFile ./clan-unlock.sh;
    })
  ];
}
