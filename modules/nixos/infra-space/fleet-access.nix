/*
  infra-space's root access on every clan machine (wired via the `sshd`
  instance's server extraModules in modules/flake-parts/nixosConfigurations.nix,
  like ../agent-user.nix).

  The key goes into root's authorizedKeys.keyFiles, not into the clan
  instance's authorizedKeys: several modules copy root's `keys` list to
  other accounts (som's hermes agents and bumper as their adminKeys, bam's
  dave, nas' users) or into the initrd, and the infra-space identity must
  reach none of them. Nothing reads `keyFiles` but sshd's own
  /etc/ssh/authorized_keys.d/root (which carries both, so hosts whose sshd
  reads only that file, like vit, admit it too) and the initrd sshd's
  authorizedKeyFiles default, which is narrowed back below.
*/
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.hyper.infraSpace.fleetAccess;
  keyFile = pkgs.writeText "infra-space-root.pub" (cfg.publicKey + "\n");
in
{
  options.hyper.infraSpace.fleetAccess.publicKey = lib.mkOption {
    type = lib.types.str;
    default = lib.trim (
      inputs.clan-core.clanLib.getPublicValue {
        flake = config.clan.core.settings.directory;
        generator = "infra-space-ssh";
        file = "id_ed25519.pub";
      }
    );
    defaultText = lib.literalMD "the shared clan var `infra-space-ssh` (./default.nix)";
    description = "The infra-space ssh public key authorized for root here.";
  };

  config = {
    users.users.root.openssh.authorizedKeys.keyFiles = [ keyFile ];
    # Its default is root's keyFiles: the unlocking initrd stays Dave's.
    boot.initrd.network.ssh.authorizedKeyFiles = lib.mkDefault (
      lib.remove keyFile config.users.users.root.openssh.authorizedKeys.keyFiles
    );
  };
}
