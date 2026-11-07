# services.hyperhermes.hardening on one agent, alice, with io_uring off
# host-wide (kernel.io_uring_disabled = 2), as on som.
#
# A probe cannot run inside the gateway itself (its tools need a model to
# be asked), so the check pins down that the real units carry the set and
# then exercises a transient unit with the same set:
#   - the gateway starts and the dashboard serves, neither restarts, and
#     their main processes run under a seccomp filter with no_new_privs;
#   - `systemctl show` gives the gateway, the dashboard, alice's user
#     manager (user@1001) and a transient unit made from
#     hardening.serviceConfig (./run.nix) the same value for every setting
#     of that set;
#   - hermes' own terminal tool (./terminal.py, through its tool registry
#     on the gateway's interpreter), in that transient unit with the
#     running gateway's environment, can neither `unshare -U` nor gain
#     root through sudo, also not through alice's user manager
#     (`systemd-run --user`, reached over the session bus the gateway
#     hands its tools), which still runs her commands;
#   - in that transient unit, as alice: `unshare -U`, io_uring_setup (also
#     with the sysctl off, so the filter alone refuses it) and sudo fail,
#     each of which works for alice outside it; `nix build` of a trivial
#     derivation and node's file I/O work.
{ pkgs, self }:
let
  inherit (pkgs) lib;
  hardenedRun = import ./run.nix { inherit lib; };

  # io_uring_setup(1, &params): the fd, or the errno's name.
  ioUringProbe = pkgs.writeText "io-uring-probe.py" ''
    import ctypes, errno
    libc = ctypes.CDLL(None, use_errno=True)
    params = ctypes.create_string_buffer(120)
    fd = libc.syscall(425, 1, params)
    print("fd" if fd >= 0 else errno.errorcode[ctypes.get_errno()])
  '';

  nodeProbe = pkgs.writeText "node-probe.js" ''
    const fs = require("fs");
    const path = require("path");
    const dir = fs.mkdtempSync(path.join(process.env.HOME, "node-probe-"));
    const file = path.join(dir, "f");
    fs.writeFileSync(file, "sync\n");
    (async () => {
      await fs.promises.appendFile(file, "async\n");
      const text = await fs.promises.readFile(file, "utf8");
      if (text !== "sync\nasync\n") throw new Error("read back " + JSON.stringify(text));
      const st = await fs.promises.stat(file);
      if (st.size !== 11) throw new Error("size " + st.size);
      await fs.promises.rm(dir, { recursive: true });
      console.log("node-ok");
    })().catch((e) => { console.error(e); process.exit(1); });
  '';

  trivialDrv = pkgs.writeText "trivial.nix" ''
    derivation {
      name = "hardening-probe";
      system = builtins.currentSystem;
      builder = "/bin/sh";
      args = [ "-c" "echo built > $out" ];
    }
  '';
in
pkgs.testers.runNixOSTest {
  name = "hyperhermes-hardening";

  nodes.machine = {
    imports = [ self.nixosModules.core ];
    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;

    services.hyperhermes = {
      pythonPackages = _: [ ];
      hardening.enable = true;
      agents.alice.uid = 1001;
    };

    boot.kernel.sysctl."kernel.io_uring_disabled" = 2;

    # The control: outside the hardening, alice's sudo makes her root.
    security.sudo.extraRules = [
      {
        users = [ "alice" ];
        commands = [
          {
            command = "ALL";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    # No network: the trivial build must not wait on a substituter.
    nix.settings.substituters = lib.mkForce [ ];
    environment.systemPackages = [
      pkgs.python3
      pkgs.nodejs
      pkgs.util-linux
      pkgs.curl
    ];
  };

  testScript =
    { nodes, ... }:
    let
      inherit (nodes.machine.services.hyperhermes.hardening) serviceConfig;
      hermes = nodes.machine.services.hyperhermes.package;
      run = hardenedRun {
        inherit serviceConfig;
        user = "alice";
      };
    in
    ''
      import base64
      import json
      import shlex

      props = "${lib.concatStringsSep "," (lib.attrNames serviceConfig)}"

      def hardened(cmd):
          return "${run} --pipe --wait --quiet --collect -- sh -c " + shlex.quote(cmd)

      def plain(cmd):
          return "runuser -u alice -- sh -c " + shlex.quote(cmd)

      # Per-unit variables systemd sets for the gateway, not part of its
      # environment proper.
      unit_vars = {"INVOCATION_ID", "JOURNAL_STREAM", "SYSTEMD_EXEC_PID", "MANAGERPID",
                   "NOTIFY_SOCKET", "CREDENTIALS_DIRECTORY", "MAINPID"}

      def terminal(cmd):
          """hermes' terminal tool, in a probe unit with the set and the
          running gateway's environment (its session bus and runtime dir
          too), on the gateway's interpreter."""
          pid = machine.succeed("systemctl show -p MainPID --value hermes-agent-alice.service").strip()
          environ = base64.b64decode(machine.succeed(f"base64 -w0 /proc/{pid}/environ")).decode()
          env = [kv for kv in environ.split("\0") if kv and kv.split("=", 1)[0] not in unit_vars]
          # Skips hermes' dangerous-command approval, which has no one to ask here.
          env.append("HERMES_YOLO_MODE=1")
          out = machine.succeed(
              "${run} --pipe --wait --quiet --collect --working-directory=${self.lib.workspace "alice"} "
              + " ".join(shlex.quote("--setenv=" + kv) for kv in env)
              + " -- ${hermes.hermesVenv}/bin/python3 ${./terminal.py} " + shlex.quote(cmd))
          line = next(l for l in reversed(out.splitlines()) if l.startswith("RESULT "))
          result = json.loads(line[len("RESULT "):])
          print(cmd, "->", result)
          return result

      machine.wait_for_unit("hermes-agent-alice.service")
      machine.wait_for_unit("hermes-dashboard-alice.service")
      machine.wait_for_unit("user@1001.service")
      assert machine.succeed("sysctl -n kernel.io_uring_disabled").strip() == "2"

      with subtest("the real units carry the set, as does the probe unit"):
          machine.succeed("${run} --unit=hardening-probe -p RemainAfterExit=yes true")
          machine.wait_until_succeeds("systemctl is-active hardening-probe.service")
          probe = machine.succeed(f"systemctl show -p {props} hardening-probe.service")
          for unit in ("hermes-agent-alice", "hermes-dashboard-alice", "user@1001"):
              shown = machine.succeed(f"systemctl show -p {props} {unit}.service")
              assert shown == probe, (unit, shown, probe)
          for line in ("NoNewPrivileges=yes", "RestrictSUIDSGID=yes", "ProtectClock=yes",
                       "ProtectKernelModules=yes", "LockPersonality=yes"):
              assert line in probe.splitlines(), (line, probe)
          assert "io_uring_setup" not in probe, probe
          machine.succeed("systemctl stop hardening-probe.service")

      with subtest("the gateway, the dashboard and alice's user manager are filtered"):
          for unit in ("hermes-agent-alice", "hermes-dashboard-alice", "user@1001"):
              pid = machine.succeed(f"systemctl show -p MainPID --value {unit}.service").strip()
              status = machine.succeed(f"cat /proc/{pid}/status")
              assert "NoNewPrivs:\t1" in status, (unit, status)
              assert "Seccomp:\t2" in status, (unit, status)

      with subtest("hermes' terminal tool is hardened, also through the owner's user manager"):
          own = terminal("id -u")
          assert own["exit_code"] == 0 and own["output"].strip() == "1001", own
          r = terminal("unshare -U true")
          assert r["exit_code"] != 0 and "Operation not permitted" in r["output"], r
          r = terminal("sudo -n id -u")
          assert r["exit_code"] != 0 and "no new privileges" in r["output"], r
          # The gateway hands its tools the owner's session bus and runtime
          # dir, so a tool reaches the lingering user manager, whose
          # children are not the gateway's.
          user = "systemd-run --user --pipe --wait --quiet -- "
          own = terminal(user + "id -u")
          assert own["exit_code"] == 0 and own["output"].strip() == "1001", own
          r = terminal(user + "/run/current-system/sw/bin/unshare -U true")
          assert r["exit_code"] != 0 and "Operation not permitted" in r["output"], r
          r = terminal(user + "/run/wrappers/bin/sudo -n id -u")
          assert r["exit_code"] != 0 and "no new privileges" in r["output"], r

      with subtest("no user namespace"):
          machine.succeed(plain("unshare -U true"))
          machine.fail(hardened("unshare -U true"))

      with subtest("no io_uring, by the sysctl and by the filter alone"):
          assert machine.succeed(plain("python3 ${ioUringProbe}")).strip() == "EPERM"
          assert machine.succeed(hardened("python3 ${ioUringProbe}")).strip() == "EPERM"
          machine.succeed("sysctl -w kernel.io_uring_disabled=0")
          assert machine.succeed(plain("python3 ${ioUringProbe}")).strip() == "fd"
          assert machine.succeed(hardened("python3 ${ioUringProbe}")).strip() == "EPERM"
          machine.succeed("sysctl -w kernel.io_uring_disabled=2")

      with subtest("a setuid binary does not elevate"):
          assert machine.succeed(plain("sudo -n id -u")).strip() == "0"
          assert machine.succeed(hardened("id -u")).strip() == "1001"
          machine.fail(hardened("sudo -n id -u"))

      with subtest("node file I/O works without io_uring"):
          assert machine.succeed(plain("node ${nodeProbe}")).strip() == "node-ok"
          assert machine.succeed(hardened("node ${nodeProbe}")).strip() == "node-ok"

      with subtest("nix builds through the daemon"):
          out = machine.succeed(hardened(
              "nix --extra-experimental-features nix-command build --no-link --print-out-paths -f ${trivialDrv}"
          )).strip()
          assert machine.succeed(f"cat {out}").strip() == "built"

      with subtest("the gateway and dashboard come up and never restart"):
          # Both are simple units, active from exec on: wait until the
          # gateway has started and the dashboard serves, past their
          # imports and first I/O, before counting restarts.
          machine.wait_until_succeeds(
              "journalctl -u hermes-agent-alice.service --no-pager | grep -q 'Hermes Gateway Starting'",
              timeout=180)
          machine.wait_until_succeeds(
              "runuser -u alice -- curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "
              "http://127.0.0.1:${toString (self.lib.dashboardBackendBase + 1001)}/ | grep -qv '^000$'",
              timeout=180)
          for unit in ("hermes-agent-alice", "hermes-dashboard-alice"):
              machine.succeed(f"systemctl is-active {unit}.service")
              assert machine.succeed(f"systemctl show -p NRestarts --value {unit}.service").strip() == "0", unit
    '';
}
