# space-gui (./default.nix) on one machine: alice (uid 1000) runs a
# headless sway (pixman), the container `gui` has the space user `gui`
# (uid 1203). Covered: a Wayland client started in the container through
# `space-gui` (alice, sudo) shows up in sway's tree and runs as the
# space's user in the container; its connection is in a security context
# (no screencopy, data-control, virtual keyboard or foreign-toplevel
# globals, which alice's own clients see); the session's socket itself
# never enters the container; xdg-open in the container opens an allowed
# https URL in alice's opener, refuses another origin and a non-loopback
# redirect_uri, and an allowed sign-in URL's loopback redirect_uri gets
# alice's 127.0.0.1:<port> forwarded to the container's loopback; when
# the client exits the run's directory is gone, in the container and
# here; another user cannot run the helper.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "space-gui";

  nodes.machine =
    { pkgs, ... }:
    let
      opener = pkgs.writeShellScript "test-opener" ''
        printf '%s\n' "$1" >> /tmp/opened
      '';
    in
    {
      imports = [ ./default.nix ];
      virtualisation.memorySize = 2048;
      users.users.alice = {
        isNormalUser = true;
        uid = 1000;
        linger = true;
        extraGroups = [ "wheel" ];
      };
      # In wheel too: the helper itself refuses anyone but alice.
      users.users.bob = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
      };
      security.sudo.execWheelOnly = true;
      programs.sway.enable = true;
      environment.systemPackages = [
        pkgs.weston
        pkgs.wayland-utils
        pkgs.curl
      ];

      containers.gui = {
        autoStart = true;
        # Its own loopback, as infra-space's private veth gives it.
        privateNetwork = true;
        config = {
          users.users.gui = {
            isNormalUser = true;
            uid = 1203;
          };
          system.stateVersion = "25.11";
        };
      };

      hyper.spaceGui = {
        enable = true;
        hostUser = "alice";
        opener = "${opener}";
        containers.gui = {
          user = "gui";
          uid = 1203;
          home = "/home/gui";
          openOrigins = [ "https://dash.example.org" ];
        };
        apps.flower = {
          container = "gui";
          command = [ "${pkgs.weston}/bin/weston-flower" ];
          desktopName = "flower (gui)";
        };
      };

      systemd.user.services.sway = {
        wantedBy = [ "default.target" ];
        environment = {
          WLR_BACKENDS = "headless";
          WLR_RENDERER = "pixman";
          WLR_LIBINPUT_NO_DEVICES = "1";
        };
        serviceConfig.ExecStart = "/run/current-system/sw/bin/sway -c /etc/sway/config";
      };
    };

  testScript = ''
    import json

    def as_alice(cmd, **kw):
        return machine.succeed(
            "su alice -c 'export XDG_RUNTIME_DIR=/run/user/1000; "
            "export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls wayland-? | head -1); "
            "export SWAYSOCK=$(ls /run/user/1000/sway-ipc.*.sock); " + cmd + "'",
            **kw,
        )

    def tree_names():
        tree = json.loads(as_alice("swaymsg -t get_tree"))
        out = []
        def walk(n):
            if n.get("pid"):
                out.append((n.get("name"), n.get("app_id"), n["pid"]))
            for k in n.get("nodes", []) + n.get("floating_nodes", []):
                walk(k)
        walk(tree)
        return out

    machine.wait_for_unit("container@gui.service")
    machine.wait_until_succeeds("systemctl -M gui is-system-running | grep -Eq 'running|degraded'")
    machine.wait_until_succeeds("ls /run/user/1000/wayland-?")
    machine.wait_until_succeeds("ls /run/user/1000/sway-ipc.*.sock")

    with subtest("a client in the container shows on alice's session"):
        machine.succeed(
            "systemd-run --uid=alice --unit=flower -E XDG_RUNTIME_DIR=/run/user/1000 "
            "-E WAYLAND_DISPLAY=$(cd /run/user/1000 && ls wayland-? | head -1) "
            "/run/current-system/sw/bin/space-gui-flower"
        )
        try:
            machine.wait_until_succeeds("su alice -c 'export SWAYSOCK=$(ls /run/user/1000/sway-ipc.*.sock); swaymsg -t get_tree' | grep -q flower", timeout=60)
        except Exception:
            print(machine.execute("journalctl -M gui -o cat --no-pager | tail -40; journalctl -u flower -o cat --no-pager")[1])
            raise
        wins = tree_names()
        match = [w for w in wins if "flower" in f"{w[0]} {w[1]}"]
        assert match, wins
        name, app_id, pid = match[0]
        # The client's process runs as the space's user, in the container.
        machine.succeed(f"[ $(stat -c %u /proc/{pid}) = 1203 ]")
        leader = machine.succeed("machinectl show gui -p Leader --value").strip()
        machine.succeed(f"[ $(readlink /proc/{pid}/ns/mnt) = $(readlink /proc/{leader}/ns/mnt) ]")
        # Only the run's directory is bound, never the session's socket.
        mounts = machine.succeed(f"grep space-gui /proc/{leader}/mountinfo")
        assert "/run/user" not in mounts and "wayland-1 " not in mounts, mounts
        machine.succeed("ls -d /run/space-gui/gui/*/")

    with subtest("its connection is in a security context"):
        host = as_alice("wayland-info")
        assert "zwlr_screencopy_manager_v1" in host, host
        guest = machine.succeed(
            "su alice -c 'XDG_RUNTIME_DIR=/run/user/1000 "
            "WAYLAND_DISPLAY=$(cd /run/user/1000 && ls wayland-? | head -1) "
            "space-gui gui ${pkgs.wayland-utils}/bin/wayland-info' 2>&1; "
            "journalctl -M gui -o cat --no-pager | grep \"^interface\""
        )
        assert "wl_compositor" in guest, guest
        for g in ["zwlr_screencopy_manager_v1", "zwlr_data_control_manager_v1", "ext_data_control_manager_v1",
                  "zwp_virtual_keyboard_manager_v1", "zwlr_foreign_toplevel_manager_v1",
                  "wp_security_context_manager_v1", "zwlr_layer_shell_v1"]:
            assert g not in guest, f"{g} offered to the container: {guest}"

    with subtest("xdg-open: allowed origin, refused others, loopback forward"):
        run = machine.succeed("ls /run/space-gui/gui/").split()[0]
        helper = machine.succeed("grep -o '/nix/store/[^ ]*space-gui-helper' $(readlink -f /run/current-system/sw/bin/space-gui)").strip()
        conf = machine.succeed(f"grep -o 'SPACE_GUI_CONFIG=[^ ]*' {helper} | cut -d= -f2").strip()
        shim = json.loads(machine.succeed(f"cat {conf}"))["shim"]
        def guest_open(url):
            return machine.execute(
                f"systemd-run -M gui --uid=gui --wait --pipe --quiet "
                f"-E SPACE_GUI_OPEN=/run/space-gui/{run}/open.sock {shim}/bin/xdg-open '{url}'"
            )
        rc, out = guest_open("https://dash.example.org/x")
        assert rc == 0, out
        machine.wait_until_succeeds("grep -qx https://dash.example.org/x /tmp/opened")
        for bad in ["https://evil.example.org/x", "http://dash.example.org/x",
                    "https://dash.example.org/a?redirect_uri=http://10.0.0.1:4444/callback"]:
            rc, out = guest_open(bad)
            assert rc != 0, f"{bad} was opened: {out}"
        machine.succeed("[ $(wc -l < /tmp/opened) = 1 ]")
        # The app's loopback listener in the container.
        machine.succeed(
            "systemd-run -M gui --uid=gui --unit=cb "
            "${pkgs.python3}/bin/python3 -m http.server --bind 127.0.0.1 --directory /tmp 47123"
        )
        machine.wait_until_succeeds("systemd-run -M gui --wait --pipe --quiet ${pkgs.curl}/bin/curl -sf http://127.0.0.1:47123/ >/dev/null")
        machine.fail("curl -sf --max-time 3 http://127.0.0.1:47123/")
        rc, out = guest_open("https://dash.example.org/authorize?code_challenge=x&redirect_uri=http%3A%2F%2F127.0.0.1%3A47123%2Fcallback&state=s")
        assert rc == 0, out
        machine.wait_until_succeeds("curl -sf --max-time 3 http://127.0.0.1:47123/ >/dev/null", timeout=30)

    with subtest("the run is cleaned up when the client exits"):
        machine.succeed("systemctl stop flower")
        leader = machine.succeed("machinectl show gui -p Leader --value").strip()
        machine.wait_until_succeeds(f"! grep -q space-gui /proc/{leader}/mountinfo", timeout=30)
        machine.succeed("[ -z \"$(ls -A /run/space-gui/gui)\" ]")
        machine.succeed("[ -z \"$(ls -A /proc/" + leader + "/root/run/space-gui)\" ]")

    with subtest("only the host user may run the helper"):
        rc, out = machine.execute("su bob -c 'WAYLAND_DISPLAY=wayland-1 space-gui gui true' 2>&1")
        assert rc != 0 and "only alice may run this" in out, out
  '';
}
