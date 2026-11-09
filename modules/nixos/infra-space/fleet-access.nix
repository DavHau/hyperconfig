/*
  infra-space's root access on every clan machine (wired via the `sshd`
  instance's server extraModules in modules/flake-parts/nixosConfigurations.nix,
  like ../agent-user.nix).

  The key goes into root's authorizedKeys.keyFiles, not into the clan
  instance's authorizedKeys: several modules copy root's `keys` list to
  other accounts (som's hermes agents as their adminKeys, bam's
  dave, nas' users) or into the initrd, and the infra-space identity must
  reach none of them. Nothing reads `keyFiles` but sshd's own
  /etc/ssh/authorized_keys.d/root (which carries both, so hosts whose sshd
  reads only that file, like vit, admit it too) and the initrd sshd's
  authorizedKeyFiles default, which is narrowed back below.
*/
{
  config,
  lib,
  ...
}:
let
  inherit (config.hyper.infraSpace.fleetAccess) keyFile;
in
{
  # A file, not a string: sshd reads keyFiles at eval time, and a file
  # written from a string (writeText) is IFD, which flake check
  # --no-build cannot build.
  options.hyper.infraSpace.fleetAccess.keyFile = lib.mkOption {
    type = lib.types.path;
    default =
      config.clan.core.settings.directory + "/vars/shared/infra-space-ssh/id_ed25519.pub/value";
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
