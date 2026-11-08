# ./storagebox.nix against a stand-in box: a server node answering as
# u632961-sub1.your-storagebox.de with the sub-account's user and a password.
# Checks the mount is lazy (only the automount at boot), readable by every
# user and read-only, and that it never hangs: with the server cut off, a
# stat under a live mount fails within the ssh keepalive window, a fresh
# mount attempt fails within the connect/mount timeouts, daemon-reload and
# stopping the mount return, and the mount comes back with the server. Last,
# a wedged (SIGSTOPped) sshfs is aborted by the kernel's FUSE request
# timeout instead of leaving the reader stuck.
{ pkgs }:
let
  inherit (pkgs) lib;
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  host = "u632961-sub1.your-storagebox.de";
  user = "u632961-sub1";
  password = "box-password";
in
pkgs.testers.runNixOSTest (
  { nodes, ... }:
  {
    name = "storagebox";

    nodes.box = {
      services.openssh = {
        enable = true;
        settings.PasswordAuthentication = true;
        hostKeys = [
          {
            path = "/etc/ssh/ssh_host_ed25519_key";
            type = "ed25519";
          }
        ];
      };
      environment.etc."ssh/ssh_host_ed25519_key" = {
        source = keys.snakeOilEd25519PrivateKey;
        mode = "0600";
      };
      users.users.${user} = {
        isNormalUser = true;
        # The real box's root is world-readable; NixOS defaults homes to 700.
        homeMode = "755";
        inherit password;
      };
    };

    nodes.client = {
      imports = [ ./storagebox.nix ];

      # Stand-in for clan's vars: only the password path is read.
      options.clan.core.vars.generators = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };
      config = {
        clan.core.vars.generators.storagebox.files.password.path = "/etc/storagebox-password";
        environment.etc."storagebox-password" = {
          text = password;
          mode = "0400";
        };
        networking.hosts.${nodes.box.networking.primaryIPAddress} = [ host ];
        programs.ssh.knownHosts.${host}.publicKey = lib.mkForce keys.snakeOilEd25519PublicKey;
      };
    };

    testScript = ''
      import time

      def timed(cmd):
          """Run cmd under a hard 300 s cap; return (status, seconds)."""
          start = time.monotonic()
          status, out = client.execute(f"timeout 300 {cmd} 2>&1")
          took = time.monotonic() - start
          client.log(f"{cmd!r}: status {status} after {took:.1f}s: {out.strip()}")
          assert status != 124, f"{cmd!r} hung for the full 300 s"
          return status, took

      start_all()
      box.wait_for_unit("sshd.service")
      box.succeed(
          "install -d -o ${user} /home/${user}/depth",
          "echo hello > /home/${user}/depth/a",
          "chown ${user} /home/${user}/depth/a",
      )
      client.wait_for_unit("multi-user.target")

      with subtest("lazy: only the automount is up after boot"):
          client.succeed("systemctl is-active mnt-storagebox.automount")
          client.fail("systemctl is-active mnt-storagebox.mount")
          client.succeed("systemctl is-active remote-fs.target")
          client.succeed("systemctl show -p TimeoutIdleUSec mnt-storagebox.automount | grep -Fx TimeoutIdleUSec=10min")
          client.succeed("test $(sysctl -n fs.fuse.default_request_timeout) = 120")

      with subtest("access mounts it, readable by all, read-only"):
          client.succeed("grep -qx hello /mnt/storagebox/depth/a")
          client.succeed("systemctl is-active mnt-storagebox.mount")
          client.succeed("runuser -u nobody -- grep -qx hello /mnt/storagebox/depth/a")
          client.fail("touch /mnt/storagebox/depth/b")
          client.wait_for_unit("storagebox-readahead.service")
          client.succeed(
              "dev=$(awk '$5 == \"/mnt/storagebox\" && / - fuse\\.sshfs / { print $3 }' /proc/self/mountinfo);"
              " test $(cat /sys/class/bdi/$dev/read_ahead_kb) = 4096"
          )

      with subtest("dead link under a live mount: errors, no hang"):
          box.block()
          status, took = timed("stat /mnt/storagebox/depth/missing-1")
          assert status != 0 and took < 90, f"stat: status {status} after {took:.0f}s"
          # Reconnect attempt: bounded by ConnectTimeout.
          status, took = timed("stat /mnt/storagebox/depth/missing-2")
          assert status != 0 and took < 45, f"stat: status {status} after {took:.0f}s"

      with subtest("daemon-reload and stop return while the box is dead"):
          client.succeed("(stat /mnt/storagebox/depth/missing-3 >/dev/null 2>&1 &)")
          status, took = timed("systemctl daemon-reload")
          assert status == 0 and took < 30, f"daemon-reload: status {status} after {took:.0f}s"
          status, took = timed("systemctl stop mnt-storagebox.mount")
          assert status == 0 and took < 45, f"stop: status {status} after {took:.0f}s"
          client.fail("systemctl is-active mnt-storagebox.mount")
          client.succeed("systemctl is-active mnt-storagebox.automount")

      with subtest("fresh mount with the box dead fails within the timeouts"):
          status, took = timed("ls /mnt/storagebox/depth")
          assert status != 0 and took < 45, f"ls: status {status} after {took:.0f}s"
          client.succeed("systemctl is-active mnt-storagebox.automount")

      with subtest("comes back with the box"):
          box.unblock()
          client.wait_until_succeeds("grep -qx hello /mnt/storagebox/depth/a", timeout=120)

      with subtest("wedged sshfs: the kernel aborts the request"):
          # sshfs runs as mount.fuse.sshfs, next to ssh and sshpass, in the
          # mount unit's cgroup: freeze all of it.
          client.succeed("systemctl kill --signal=STOP mnt-storagebox.mount")
          status, took = timed("stat /mnt/storagebox/depth/missing-4")
          assert status != 0 and took < 200, f"stat: status {status} after {took:.0f}s"
          client.succeed("systemctl kill --signal=CONT mnt-storagebox.mount")
          status, took = timed("systemctl stop mnt-storagebox.mount")
          assert status == 0 and took < 45, f"stop: status {status} after {took:.0f}s"
          client.wait_until_succeeds("grep -qx hello /mnt/storagebox/depth/a", timeout=120)
    '';
  }
)
