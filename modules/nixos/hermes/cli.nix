# Host entry points: the `hermes` CLI shim (ssh-exec into the caller's
# VM over vsock), the `hermes-desktop` Electron wrapper against the
# forwarded dashboard, and .desktop launcher entries for both.
{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.hermes-microvm;
  hlib = import ./lib.nix { inherit lib; };
  inherit (hlib) guestStateDir;

  # Case arms mapping the invoking user to their VM's endpoints.
  userCaseArms = lib.concatStrings (lib.mapAttrsToList (user: ucfg: ''
    ${user})
      cid=${toString ucfg.uid}
      dashboard_port=${toString ucfg.dashboardPort}
      ;;
  '') cfg.users);

  # Host CLI shim: routes every `hermes` invocation into the caller's VM.
  hermesShim = pkgs.writeShellScriptBin "hermes" ''
    # `hermes desktop` is a host-side GUI (guests are headless): route it
    # to the hermes-desktop wrapper instead of ssh-execing into the VM.
    if [ "''${1:-}" = "desktop" ]; then
      shift
      exec ${hermesDesktop}/bin/hermes-desktop "$@"
    fi
    u="$(${pkgs.coreutils}/bin/id -un)"
    case "$u" in
    ${userCaseArms}
    *)
      echo "hermes: no hermes microvm configured for user $u" >&2
      exit 1
      ;;
    esac
    # Fail fast while the VM is down (clearer than ssh's pinned-key error).
    ${pkgs.systemd}/bin/systemctl is-active --quiet "microvm@hermes-$u.service" || {
      echo "hermes: microvm@hermes-$u is not running (systemctl status microvm@hermes-$u)" >&2
      exit 1
    }
    base="/var/lib/hermes-microvm/$u"
    tty_flag=""
    if [ -t 0 ] && [ -t 1 ]; then tty_flag="-t"; fi
    # ssh only carries TERM; embed COLORTERM/LANG/LC_ALL shell-quoted in
    # the remote command (TUI colors + UTF-8 glyphs). Deliberately NOT
    # WAYLAND_DISPLAY: the host clipboard is never bridged into the VM —
    # hermes's clipboard path stays disabled, paste degrades gracefully.
    env_exports=""
    for v in COLORTERM LANG LC_ALL; do
      eval "val=\''${$v:-}"
      if [ -n "$val" ]; then
        env_exports="$env_exports export $v=$(printf '%q' "$val") &&"
      fi
    done
    remote_cmd="$env_exports cd /home/$u/hermes/workspace && export HERMES_HOME=${guestStateDir}/.hermes && exec /run/current-system/sw/bin/hermes"
    # printf %q with zero args would still emit one empty-string argument
    if [ "$#" -gt 0 ]; then remote_cmd="$remote_cmd $(printf '%q ' "$@")"; fi
    # ControlMaster=no: keep the user's global ssh mux config out of this
    # connection (its socket mismatch printed "disabling multiplexing"
    # noise into the TUI).
    exec ${pkgs.openssh}/bin/ssh $tty_flag \
      -i "$base/ssh/client_ed25519" \
      -o IdentitiesOnly=yes \
      -o UserKnownHostsFile="$base/ssh/known_hosts" \
      -o StrictHostKeyChecking=yes \
      -o HostKeyAlias="hermes-$u" \
      -o ProxyCommand="${pkgs.systemd}/lib/systemd/systemd-ssh-proxy vsock/$cid 22" \
      -o ProxyUseFdpass=yes \
      -o ControlMaster=no -o ControlPath=none \
      "$u@hermes-$u" -- \
      "$remote_cmd"
  '';

  # Upstream Electron desktop app (nixpkgs electron + npm-built renderer).
  desktopPackage = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.desktop;

  # Host launcher: the upstream app in remote-backend mode against the
  # owner's forwarded dashboard. Token file 0400 + uid-gated port keep
  # the exported token owner-confined.
  hermesDesktop = pkgs.writeShellScriptBin "hermes-desktop" ''
    u="$(${pkgs.coreutils}/bin/id -un)"
    case "$u" in
    ${userCaseArms}
    *)
      echo "hermes-desktop: no hermes microvm configured for user $u" >&2
      exit 1
      ;;
    esac
    base="/var/lib/hermes-microvm/$u"
    # Fail fast while the VM is down (the root-held forward socket would
    # otherwise just drop the connection).
    ${pkgs.systemd}/bin/systemctl is-active --quiet "microvm@hermes-$u.service" || {
      echo "hermes-desktop: microvm@hermes-$u is not running" >&2
      exit 1
    }
    token="$(${pkgs.coreutils}/bin/cat "$base/desktop-token" 2>/dev/null || true)"
    if [ -z "$token" ]; then
      echo "hermes-desktop: cannot read $base/desktop-token (VM not provisioned yet?)" >&2
      exit 1
    fi
    export HERMES_DESKTOP_REMOTE_URL="http://127.0.0.1:$dashboard_port"
    export HERMES_DESKTOP_REMOTE_TOKEN="$token"
    exec ${desktopPackage}/bin/hermes-desktop "$@"
  '';
  # Neither the upstream desktop package nor the shims ship .desktop
  # files — provide launcher entries against the host wrappers (absolute
  # store paths; launchers don't inherit a useful PATH). The TUI entry is
  # Terminal=true and wraps the shim so a fast failure (VM down) doesn't
  # just flash and vanish with the window.
  hermesIcon = "${desktopPackage}/share/hermes-desktop/dist/hermes.png";

  hermesTuiLauncher = pkgs.writeShellScriptBin "hermes-tui" ''
    ${hermesShim}/bin/hermes "$@"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '\nhermes exited with status %d — press Enter to close\n' "$rc"
      read -r _
    fi
    exit "$rc"
  '';

  hermesDesktopItem = pkgs.makeDesktopItem {
    name = "hermes-desktop";
    desktopName = "Hermes Desktop";
    comment = "Hermes Agent desktop app (microvm backend)";
    exec = "${hermesDesktop}/bin/hermes-desktop";
    icon = hermesIcon;
    categories = [ "Network" "Chat" ];
  };

  hermesTuiItem = pkgs.makeDesktopItem {
    name = "hermes-tui";
    desktopName = "Hermes TUI";
    comment = "Hermes Agent terminal UI (ssh into the microvm)";
    exec = "${hermesTuiLauncher}/bin/hermes-tui";
    icon = hermesIcon;
    terminal = true;
    categories = [ "Network" "ConsoleOnly" ];
  };
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      hermesShim hermesDesktop
      hermesDesktopItem hermesTuiItem
    ];
  };
}
