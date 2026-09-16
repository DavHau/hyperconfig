# Lingering for every normal user: their `systemd --user` manager starts at
# boot and survives logout, so units in ~/.config/systemd/user run like
# services without anyone touching the NixOS config or holding root
# (`loginctl enable-linger` is admin-only under polkit).
#
# Not expressed as `users.users.<n>.linger = true` for all users: deriving
# `users.users` from `config.users.users` is infinite recursion. Instead a
# oneshot alongside NixOS's own `linger-users` (config/users-groups.nix)
# that calls loginctl for the isNormalUser set. An explicit
# `users.users.<n>.linger = false` still wins: it is disabled first, and
# we skip it here.
{ config, lib, ... }:
let
  lingering = lib.filter (u: u.isNormalUser && u.linger != false) (
    lib.attrValues config.users.users
  );
  names = map (u: u.name) lingering;
in
{
  systemd.services.linger-normal-users = {
    wantedBy = [ "multi-user.target" ];
    after = [
      "systemd-logind.service"
      "linger-users.service"
    ];
    requires = [ "systemd-logind.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      ${config.systemd.package}/bin/loginctl enable-linger ${lib.escapeShellArgs names}
    '';
  };
}
