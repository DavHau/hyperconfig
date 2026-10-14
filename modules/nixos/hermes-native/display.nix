# A virtual X display per agent, so its browsers run headful: bot walls
# single out headless Chromium (HeadlessChrome UA, headless-only traits).
#
# Xvfb runs as the agent's uid and listens on exactly one filesystem
# socket: no TCP, no abstract socket (-nolisten local; a private network
# namespace besides). Xvfb cannot move its socket out of the
# world-shared /tmp/.X11-unix, so the unit gets a private /tmp with
# <x11 dir>/sock bound over that path. Xvfb makes that dir 1777, as it
# would /tmp/.X11-unix; the 0700 x11 dir around it, inside the 0700
# state dir, keeps every other uid out. Clients dial the socket by path
# (DISPLAY=<x11 dir>/sock/X0, libxcb >= 1.15), and a fresh MIT cookie
# per start gates the connection on top.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hermes-native;
  hlib = import ./lib.nix { inherit lib; };

  # Family wild (ffff) for display 0: libxcb reports a path-form DISPLAY
  # as display 0 on no particular host. printf is a builtin, so the
  # cookie never shows in a command line.
  writeCookie =
    dir:
    pkgs.writeShellScript "hermes-xvfb-cookie" ''
      set -eu
      umask 0077
      : > ${dir}/Xauthority.new
      printf 'ffff 0000  0001 30 0012 4d49542d4d414749432d434f4f4b49452d31 0010 %s\n' \
        "$(${pkgs.coreutils}/bin/od -An -N16 -tx1 /dev/urandom | ${pkgs.coreutils}/bin/tr -d ' \n')" \
        | ${pkgs.xauth}/bin/xauth -q -f ${dir}/Xauthority.new nmerge -
      ${pkgs.coreutils}/bin/mv ${dir}/Xauthority.new ${dir}/Xauthority
    '';
in
{
  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = lib.concatLists (
      lib.mapAttrsToList (user: _: [
        "d ${hlib.x11Dir user} 0700 ${user} users - -"
        "d ${hlib.x11Dir user}/sock 0700 ${user} users - -"
      ]) cfg.users
    );

    systemd.services = lib.mkMerge (
      lib.mapAttrsToList (
        user: _:
        let
          dir = hlib.x11Dir user;
        in
        {
          "hermes-xvfb-${user}" = {
            description = "Virtual X display of hermes agent ${user}";
            unitConfig.RequiresMountsFor = [ dir ];
            serviceConfig = {
              User = user;
              Group = "users";
              ExecStartPre = writeCookie dir;
              # Display :0 in every agent's own /tmp; the numbers never meet.
              ExecStart = "${pkgs.xvfb}/bin/Xvfb :0 -nolisten tcp -nolisten local -auth ${dir}/Xauthority -screen 0 1920x1080x24";
              PrivateTmp = true;
              BindPaths = [ "${dir}/sock:/tmp/.X11-unix" ];
              PrivateNetwork = true;
              MemoryMax = "512M";
              Restart = "always";
              RestartSec = 2;
            };
          };

          "hermes-agent-${user}" = {
            wants = [ "hermes-xvfb-${user}.service" ];
            after = [ "hermes-xvfb-${user}.service" ];
          };
        }
      ) cfg.users
    );
  };
}
