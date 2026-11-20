# space-gui (./default.nix) on one machine: alice (uid 1000) runs a
# headless sway (pixman), the container `gui` has the space user `gui`
# (uid 1203). Covered: a Wayland client started in the container through
# `space-gui` (alice, sudo) shows up in sway's tree and runs as the
# space's user in the container; its connection is in a security context
# (no screencopy, data-control, virtual keyboard or foreign-toplevel
# globals, which alice's own clients see); the session's socket itself
# never enters the container; xdg-open in the container opens an allowed
# https URL in alice's opener, refuses another origin and a non-loopback
# redirect_uri (with openAnyHttps on: any https URL opens, no forward for
# a non-allowed origin's loopback redirect_uri, still https only, the
# sixth open within 10 s refused), and an allowed sign-in URL's loopback redirect_uri gets
# alice's 127.0.0.1:<port> forwarded to the container's loopback, one
# shot (closed once the callback request is answered), refused for a port
# outside the app's ephemeral range; when the client exits the run's
# directory is gone, in the container and here; another user cannot run
# the helper.
#
# No route (../spaces/host.nix, chain no-route): a stand-in internet in a
# network namespace (192.0.2.2, 2001:db8:5::2, 2001:db8:99::1 behind it).
# With no v6 route here, 30 parallel connects of the guest to a global v6
# address all fail within 1 s (not after the kernel's rate-limited ICMP
# and SYN retries, which took up to 5 s), while v4 and this host's own
# v6 address work; with a route, the same v6 connect succeeds; and
# without it again, it fails fast again.
#
# Light/dark (./color-scheme.py): a stand-in for alice's session portal
# (Settings, value from /tmp/host-scheme) says dark, then light; an app run
# through space-gui sees it in the run's portal (ReadOne), its env and its
# gtk settings.ini, nothing else of the portal; a running app's run follows
# a change; dark when alice's session
# has no portal, and a real Electron app's nativeTheme starts in the host's
# scheme, dark and light.
#
# The container is set up like the isolated hermes desktops
# (../dave-desktop/isolated-apps.nix): through ../spaces/host.nix with
# hostNixDaemon = false, so this test also checks that the guest has no
# way to the host's nix-daemon (no socket, no nix, a daemon client
# refused) while the host's own client reaches it.
{ pkgs }:
let
  # The host session's portal Settings (the stand-in for alice's
  # xdg-desktop-portal: same interface and replies, the value from
  # /tmp/host-scheme), on alice's session bus.
  colorScheme = pkgs.writeShellScript "color-scheme" ''
    exec ${pkgs.python3.withPackages (p: [ p.dbus-fast ])}/bin/python3 ${./color-scheme.py} "$@"
  '';
  # What an app in the container sees of the light/dark preference:
  # the run's portal, its env, its gtk settings.ini.
  probe = pkgs.writeShellScript "scheme-probe" ''
    out=$HOME/scheme-$1
    {
      echo "portal=$(${pkgs.systemd}/bin/busctl --user call org.freedesktop.portal.Desktop \
        /org/freedesktop/portal/desktop org.freedesktop.portal.Settings ReadOne ss \
        org.freedesktop.appearance color-scheme)"
      echo "env=$SPACE_GUI_COLOR_SCHEME"
      for d in ''${XDG_CONFIG_DIRS//:/ }; do
        [ -f "$d/gtk-3.0/settings.ini" ] && echo "gtk3=$(grep prefer-dark "$d/gtk-3.0/settings.ini")" && break
      done
    } > $out.tmp
    mv $out.tmp $out
  '';
  # A real Electron app: nativeTheme.shouldUseDarkColors once it is
  # ready, to ~/electron-theme, then it quits.
  electronApp = pkgs.writeTextDir "main.js" ''
    const { app, nativeTheme } = require("electron");
    const fs = require("fs");
    app.whenReady().then(() => setTimeout(() => {
      fs.writeFileSync(process.env.HOME + "/electron-theme", nativeTheme.shouldUseDarkColors ? "dark" : "light");
      app.exit(0);
    }, 1500));
  '';
  electronRun = pkgs.writeShellScript "electron-theme" ''
    rm -f $HOME/electron-theme
    exec ${pkgs.electron}/bin/electron --no-sandbox --disable-gpu --ozone-platform=wayland ${electronApp}/main.js
  '';
in
pkgs.testers.runNixOSTest {
  name = "space-gui";

  nodes.machine =
    { lib, pkgs, ... }:
    let
      opener = pkgs.writeShellScript "test-opener" ''
        printf '%s\n' "$1" >> /tmp/opened
      '';
      # Its own loopback behind a private veth, as the hermes desktop
      # spaces' host side gives it.
      space =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        {
          config = import ../spaces/host.nix { inherit config lib pkgs; } {
            name = "gui";
            uid = 1203;
            hostAddress = "10.235.9.1";
            localAddress = "10.235.9.2";
            hostAddress6 = "fd23:5ace:9::1";
            localAddress6 = "fd23:5ace:9::2";
            stateDir = "/var/lib/gui-space";
            homeDir = "/var/lib/gui-space/home";
            guestHome = "/home/gui";
            tpm = false;
            credentials = { };
            hostNixDaemon = false;
            specialArgs = { };
            guestConfig = {
              users.users.gui = {
                isNormalUser = true;
                uid = 1203;
              };
              system.stateVersion = "25.11";
            };
          };
        };
    in
    {
      imports = [
        ./default.nix
        space
        # the container's own user namespace needs an idmappable store
        (import ../spaces/test-daemon.nix { inherit pkgs; }).hostModule
      ];
      virtualisation.memorySize = 3072;
      # used by the test script only
      system.extraDependencies = [
        probe
        electronRun
      ];
      # alice's session portal (Settings only), started by the test script
      # and the only one: sway's default xdg-desktop-portal would be
      # D-Bus activated by the helper's first read and own the name
      xdg.portal.enable = lib.mkForce false;
      systemd.user.services.host-portal = {
        environment.SPACE_GUI_COLOR_SCHEME_FILE = "/tmp/host-scheme";
        serviceConfig = {
          ExecStart = "${colorScheme} portal";
          # `systemctl start` returns once the name is owned
          Type = "dbus";
          BusName = "org.freedesktop.portal.Desktop";
        };
      };
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
    import shlex

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
        # The client's process runs as the space's user, in the container
        # (its own user namespace: here the container's base + 1203).
        leader = machine.succeed("machinectl show gui -p Leader --value").strip()
        base = int(machine.succeed(f"cat /proc/{leader}/uid_map").split()[1])
        assert base >= 0x50000000, base
        machine.succeed(f"[ $(stat -c %u /proc/{pid}) = {base + 1203} ]")
        machine.succeed(f"[ $(readlink /proc/{pid}/ns/mnt) = $(readlink /proc/{leader}/ns/mnt) ]")
        # Only the container's run directories are bound, never the
        # session's socket.
        mounts = machine.succeed(f"grep space-gui /proc/{leader}/mountinfo")
        assert "/run/user" not in mounts and "wayland-1 " not in mounts, mounts
        machine.succeed("ls -d /run/space-gui/gui/*/")

    with subtest("its connection is in a security context"):
        host = as_alice("wayland-info")
        assert "zwlr_screencopy_manager_v1" in host, host
        guest = machine.succeed(
            "su alice -c 'XDG_RUNTIME_DIR=/run/user/1000 "
            "WAYLAND_DISPLAY=$(cd /run/user/1000 && ls wayland-? | head -1) "
            "space-gui gui ${pkgs.wayland-utils}/bin/wayland-info' 2>&1"
        )
        # its output reaches the guest's journal a moment later
        guest += machine.wait_until_succeeds(
            "journalctl -M gui -o cat --no-pager | grep \"^interface\"", timeout=30
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
        # Outside the app's ephemeral range (listen(0)): refused.
        rc, out = guest_open("https://dash.example.org/a?redirect_uri=http%3A%2F%2F127.0.0.1%3A8080%2Fcallback")
        assert rc != 0, f"port 8080 was forwarded: {out}"
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
        # Open until the callback: other requests pass and keep it open.
        machine.wait_until_succeeds("curl -sf --max-time 3 http://127.0.0.1:47123/ >/dev/null", timeout=30)
        machine.succeed("curl -sf --max-time 3 http://127.0.0.1:47123/ >/dev/null")
        # The callback (http.server answers 404 for it, as good as the
        # app's page) gets its answer, then the forward closes: one shot.
        machine.succeed("curl -s --max-time 5 -o /dev/null -w '%{http_code}' 'http://127.0.0.1:47123/callback?code=c&state=s' | grep -qx 404")
        machine.wait_until_fails("curl -s --max-time 3 http://127.0.0.1:47123/ >/dev/null", timeout=15)
        # Still listening in the container.
        machine.succeed("systemd-run -M gui --wait --pipe --quiet ${pkgs.curl}/bin/curl -sf http://127.0.0.1:47123/ >/dev/null")

    with subtest("no way to the host's nix-daemon from the guest"):
        # The host's own client reaches it.
        machine.succeed("nix store ping --store daemon --extra-experimental-features nix-command")
        leader = machine.succeed("machinectl show gui -p Leader --value").strip()
        # No socket in the guest's file system, nothing bound there.
        rc, out = machine.execute(f"ls -la /proc/{leader}/root/nix/var/nix/daemon-socket/")
        assert "socket" not in out, out
        machine.fail(f"[ -S /proc/{leader}/root/nix/var/nix/daemon-socket/socket ]")
        # The guest has no nix, and the host's nix run as the guest user
        # inside finds no daemon.
        machine.fail("systemd-run -M gui --uid=gui --wait --pipe --quiet /run/current-system/sw/bin/nix-store --version")
        nix = "${pkgs.nix}/bin/nix"
        rc, out = machine.execute(
            f"systemd-run -M gui --uid=gui --wait --pipe --quiet {nix} store ping --store daemon "
            "--extra-experimental-features nix-command 2>&1"
        )
        assert rc != 0, f"the guest reached the host's nix-daemon: {out}"
        rc, out = machine.execute(
            f"systemd-run -M gui --uid=gui --wait --pipe --quiet {nix} build --store daemon "
            "--extra-experimental-features nix-command --impure --expr "
            "'derivation { name = \"x\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }' 2>&1"
        )
        assert rc != 0, f"the guest built through the host's nix-daemon: {out}"
        print(out)

    with subtest("no route: the guest's connect fails at once, v4 and a routed v6 work"):
        # a stand-in internet behind a veth of this host: 192.0.2.2 and
        # 2001:db8:5::2 on the link, 2001:db8:99::1 behind it, routed here
        # only when the test adds the route (as amy's Wi-Fi gives or not)
        machine.succeed(
            "ip netns add inet",
            "ip link add inet0 type veth peer name eth0 netns inet",
            "ip addr add 192.0.2.1/24 dev inet0",
            "ip -6 addr add 2001:db8:5::1/64 dev inet0 nodad",
            "ip link set inet0 up",
            "ip -n inet link set lo up",
            "ip -n inet link set eth0 up",
            "ip -n inet addr add 192.0.2.2/24 dev eth0",
            "ip -n inet -6 addr add 2001:db8:5::2/64 dev eth0 nodad",
            "ip -n inet -6 addr add 2001:db8:99::1/128 dev lo",
            "ip -n inet -6 route add default via 2001:db8:5::1",
            "systemd-run --unit=inet-listener ip netns exec inet "
            "${pkgs.socat}/bin/socat TCP6-LISTEN:80,ipv6only=0,reuseaddr,fork EXEC:true",
        )
        machine.wait_until_succeeds("ip netns exec inet ss -Htln 'sport = :80' | grep -q .")
        # no v6 default route here (as amy on a v4-only Wi-Fi)
        machine.succeed("sysctl -w net.ipv6.conf.all.accept_ra=0 net.ipv6.conf.default.accept_ra=0",
                        "ip -6 route flush default || true")
        print(machine.succeed("ip -6 route"))
        machine.fail("ip -6 route get 2001:db8:99::1")

        def in_gui(cmd):
            return machine.succeed("nixos-container run gui -- bash -c " + shlex.quote(cmd))

        # 30 at once, as an Electron app's happy eyeballs opens them; each
        # gets 5 s, longer than the kernel's own (rate-limited) answer took
        parallel = (
            "s=$(date +%s%N); "
            "for i in $(seq 1 30); do "
            "  ( timeout 5 bash -c 'echo > /dev/tcp/2001:db8:99::1/80' 2>/dev/null && echo connected ) & "
            "done; wait; "
            "echo ms=$(( ($(date +%s%N) - s) / 1000000 ))"
        )

        def fails_fast():
            out = in_gui(parallel)
            assert "connected" not in out, out
            ms = int(out.split("ms=")[1].split()[0])
            assert ms < 1000, f"30 v6 connects without a route took {ms} ms: {out}"
            # other protocols: an ICMP no-route at once, not silence
            out = in_gui("${pkgs.iputils}/bin/ping -6 -c 1 -W 3 2001:db8:99::1 2>&1 || true")
            assert "unreachable" in out.lower(), out

        fails_fast()
        # v4 works meanwhile (masqueraded out), and this host's own v6
        # address is no forward and stays reachable
        in_gui("timeout 5 bash -c 'echo > /dev/tcp/192.0.2.2/80'")
        in_gui("${pkgs.iputils}/bin/ping -6 -c 1 -W 2 fd23:5ace:9::1")
        # a route: v6 goes out
        machine.succeed("ip -6 route add 2001:db8:99::/48 via 2001:db8:5::2")
        in_gui("timeout 5 bash -c 'echo > /dev/tcp/2001:db8:99::1/80'")
        # gone again (amy leaves the network): fast again
        machine.succeed("ip -6 route del 2001:db8:99::/48")
        fails_fast()
        machine.succeed("systemctl stop inet-listener; ip netns del inet")

    with subtest("light/dark: the host session's preference, dark by default, followed live"):
        home = "/var/lib/gui-space/home"
        def seen(word):
            machine.succeed(f"rm -f {home}/scheme-{word}")
            as_alice(f"space-gui gui ${probe} {word}")
            out = machine.succeed(f"cat {home}/scheme-{word}")
            print(word, out)
            return out
        def expect(out, dark):
            assert f"portal=v u {1 if dark else 2}" in out, out
            assert f"env={'dark' if dark else 'light'}" in out, out
            assert f"gtk3=gtk-application-prefer-dark-theme={int(dark)}" in out, out
        machine.succeed("echo dark > /tmp/host-scheme && chmod 644 /tmp/host-scheme")
        as_alice("systemctl --user start host-portal")
        def host_says(word):
            # the stand-in reads its file once a second
            machine.succeed(f"echo {word} > /tmp/host-scheme")
            n = 1 if word == "dark" else 2
            machine.wait_until_succeeds(
                "su alice -c 'XDG_RUNTIME_DIR=/run/user/1000 busctl --user call org.freedesktop.portal.Desktop "
                "/org/freedesktop/portal/desktop org.freedesktop.portal.Settings ReadOne ss "
                f"org.freedesktop.appearance color-scheme' | grep -qx 'v u {n}'", timeout=30)
        host_says("dark")
        expect(seen("dark"), True)
        host_says("light")
        expect(seen("light"), False)
        # the running flower run (started before alice's portal) follows
        # every change: its file, which the run's portal serves and
        # announces
        machine.wait_until_succeeds(f"grep -qx light /run/space-gui/gui/{run}/color-scheme", timeout=15)
        host_says("dark")
        machine.wait_until_succeeds(f"grep -qx dark /run/space-gui/gui/{run}/color-scheme", timeout=15)
        host_says("light")
        machine.wait_until_succeeds(f"grep -qx light /run/space-gui/gui/{run}/color-scheme", timeout=15)
        # the run's portal answers only that key
        rc, out = machine.execute(
            "su alice -c 'XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=$(cd /run/user/1000 && ls wayland-? | head -1) "
            "space-gui gui ${pkgs.systemd}/bin/busctl --user call org.freedesktop.portal.Desktop "
            "/org/freedesktop/portal/desktop org.freedesktop.portal.Settings ReadOne ss org.gnome.desktop.interface gtk-theme' 2>&1"
        )
        assert rc != 0, out
        # no portal on the host: dark
        as_alice("systemctl --user stop host-portal")
        expect(seen("fallback"), True)

        # A real Electron app starts in the host's scheme (Electron reads
        # GTK's prefer-dark setting, not the portal: no live follow).
        as_alice("systemctl --user start host-portal")
        for word in ["dark", "light"]:
            host_says(word)
            machine.succeed(f"rm -f {home}/electron-theme")
            try:
                as_alice("space-gui gui ${electronRun}", timeout=120)
                machine.succeed(f"grep -qx {word} {home}/electron-theme")
            finally:
                print(machine.execute(f"cat {home}/electron-theme; journalctl -M gui -o cat --no-pager | tail -15")[1])

    with subtest("the run is cleaned up when the client exits"):
        machine.succeed("systemctl stop flower")
        leader = machine.succeed("machinectl show gui -p Leader --value").strip()
        # the container's /run/space-gui stays bound (./default.nix), the
        # run's directory goes
        machine.wait_until_succeeds("[ -z \"$(ls -A /run/space-gui/gui)\" ]", timeout=30)
        mounts = machine.succeed(f"grep space-gui /proc/{leader}/mountinfo").strip().splitlines()
        assert len(mounts) == 1 and " /run/space-gui " in mounts[0], mounts
        machine.succeed("[ -z \"$(ls -A /proc/" + leader + "/root/run/space-gui)\" ]")

    with subtest("openAnyHttps: any https link opens, no forward for it, https only, rate limit"):
        # The `gui` run above is strict (openAnyHttps off: evil.example.org
        # refused). A second run with the same container's config but
        # openAnyHttps on, started as sudo would (root, SUDO_UID of alice).
        any_conf = json.loads(machine.succeed(f"cat {conf}"))
        assert any_conf["containers"]["gui"]["openAnyHttps"] is False, any_conf
        any_conf["containers"]["gui"]["openAnyHttps"] = True
        machine.succeed(f"echo {shlex.quote(json.dumps(any_conf))} > /tmp/any.json")
        machine.succeed(f"sed 's|SPACE_GUI_CONFIG=.*|SPACE_GUI_CONFIG=/tmp/any.json|' {helper} > /tmp/any-helper && chmod +x /tmp/any-helper")
        display = machine.succeed("cd /run/user/1000 && ls wayland-? | head -1").strip()
        machine.succeed(
            f"systemd-run --unit=anyhttps -E SUDO_UID=1000 "
            f"/tmp/any-helper gui {display} ${pkgs.coreutils}/bin/sleep infinity"
        )
        machine.wait_until_succeeds("ls /run/space-gui/gui/*/open.sock", timeout=30)
        run2 = machine.succeed("ls /run/space-gui/gui/").split()[0]
        def open2(url):
            return machine.execute(
                f"systemd-run -M gui --uid=gui --wait --pipe --quiet "
                f"-E SPACE_GUI_OPEN=/run/space-gui/{run2}/open.sock {shim}/bin/xdg-open {shlex.quote(url)}"
            )
        machine.succeed("rm -f /tmp/opened")
        # the container's opens window (5 per 10 s) starts empty
        machine.sleep(11)
        rc, out = open2("https://other.example.net/page?x=1")
        assert rc == 0, out
        machine.wait_until_succeeds("grep -qx 'https://other.example.net/page?x=1' /tmp/opened")
        # Still https only, whatever the origin; refusals do not count.
        for bad in ["http://other.example.net/x", "file:///etc/passwd", "javascript:alert(1)",
                    "-https://other.example.net/", "https:///nohost", "https://other.example.net/\tx",
                    "https://other.example.net/" + "a" * 9000]:
            rc, out = open2(bad)
            assert rc != 0, f"{bad[:80]} was opened: {out}"
        # Not a dashboard URL: its loopback redirect_uri gets no forward.
        machine.succeed(
            "systemd-run -M gui --uid=gui --unit=cb2 "
            "${pkgs.python3}/bin/python3 -m http.server --bind 127.0.0.1 --directory /tmp 47124"
        )
        machine.wait_until_succeeds("systemd-run -M gui --wait --pipe --quiet ${pkgs.curl}/bin/curl -sf http://127.0.0.1:47124/ >/dev/null")
        rc, out = open2("https://other.example.net/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A47124%2Fcallback")
        assert rc == 0, out
        machine.wait_until_succeeds("grep -q '^https://other.example.net/authorize' /tmp/opened")
        machine.sleep(1)
        machine.fail("ss -Htln 'sport = :47124' | grep -q .")
        machine.fail("curl -sf --max-time 3 http://127.0.0.1:47124/")
        # 2 opened so far: 3 more pass, the 6th within 10 s is refused.
        for i in range(3):
            rc, out = open2(f"https://other.example.net/n{i}")
            assert rc == 0, out
        rc, out = open2("https://other.example.net/sixth")
        assert rc != 0, f"6th open in 10 s was opened: {out}"
        machine.succeed("journalctl -u anyhttps -o cat --no-pager | grep -q 'refused: more than 5 opens'")
        machine.sleep(1)
        machine.succeed("[ $(wc -l < /tmp/opened) = 5 ] && ! grep -q sixth /tmp/opened")
        machine.succeed("systemctl stop anyhttps; systemctl -M gui stop cb2")

    with subtest("only the host user may run the helper"):
        rc, out = machine.execute("su bob -c 'WAYLAND_DISPLAY=wayland-1 space-gui gui true' 2>&1")
        assert rc != 0 and "only alice may run this" in out, out
  '';
}
