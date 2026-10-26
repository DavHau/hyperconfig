# The agents' login accounts. Per agent:
#   - a normal account with the pinned uid, so the backend ports derive
#     from it and a host the agent ssh-es into can mirror the identity,
#   - bash as login shell: hermes-desktop's SSH connection kind runs its
#     remote probe and `hermes serve` as POSIX sh one-liners
#     (`help="$(...)"`) in the login shell, which fish rejects,
#   - linger: the agent units reach the owner's session bus under
#     /run/user/<uid>, which exists from boot only while the account
#     lingers,
#   - its own outbound ssh key (sshKeyFile) for the hosts in sshKeyHosts,
#     and no other key there.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes;
  keyed = lib.filterAttrs (_: a: a.sshKeyFile != null) cfg.agents;
in
{
  config = lib.mkIf (cfg.agents != { }) {
    users.users = lib.mapAttrs (
      _: a:
      {
        isNormalUser = true;
        inherit (a) uid;
        shell = pkgs.bash;
        linger = true;
        openssh.authorizedKeys.keys = a.sshKeys;
      }
      // lib.optionalAttrs (a.description != null) { inherit (a) description; }
    ) cfg.agents;

    programs.ssh.extraConfig = lib.mkIf (cfg.sshKeyHosts != [ ]) (
      lib.concatStrings (
        lib.mapAttrsToList (name: a: ''
          Match host ${lib.concatStringsSep "," cfg.sshKeyHosts} localuser ${name}
            IdentityFile ${a.sshKeyFile}
            IdentitiesOnly yes
        '') keyed
      )
    );
  };
}
