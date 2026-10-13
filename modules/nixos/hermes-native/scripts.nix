# Root ExecStartPre helpers of hermes-agent-<user>. Vendored from spaces
# 6d744780 modules/nixos/hermes/scripts.nix (native subset).
{
  lib,
  pkgs,
  hlib,
}:
{
  # Generate the dashboard session token before the unit that loads it as
  # a credential starts: LoadCredential= resolves before a unit's own
  # ExecStartPre, so hermes-agent-<user> mints it for
  # hermes-dashboard-<user>. Owner 0400; the owner's desktop clients read
  # the same file.
  desktopTokenScript =
    user:
    pkgs.writeShellScript "hermes-desktop-token-${user}" ''
      set -eu
      export PATH=${
        lib.makeBinPath (
          with pkgs;
          [
            coreutils
            openssl
          ]
        )
      }
      token=${hlib.baseDir user}/desktop-token
      if [ ! -f "$token" ]; then
        (umask 277; openssl rand -hex 32 | tr -d '\n' > "$token")
      fi
      chown ${user} "$token"
      chmod 0400 "$token"
    '';

  # A missing config repo fails the agent start with a message that
  # names the directory and both options that can declare one.
  configRepoCheckScript =
    user: dirs:
    pkgs.writeShellScript "hermes-config-repo-check-${user}" (
      lib.concatMapStrings (dir: ''
        if [ ! -d "${dir}" ]; then
          echo "${dir} is a NixOS config repo of hermes-agent-${user}, but it does not exist. Clone it there, or drop it from services.spaces-integrations.nixos.repos and services.hermes-native.users.${user}.nixosConfigDir." >&2
          exit 1
        fi
      '') dirs
    );
}
