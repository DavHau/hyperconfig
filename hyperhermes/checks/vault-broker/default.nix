# The vault broker (modules/core/vault-broker.nix) in one container
# (systemd-nspawn, no VM): agents alice and bob; alice's gateway unit runs
# a stand-in (./gateway.py) as its main process, which resolves vault
# items through hermes' own (patched) VaultStore as browser_vault's fill
# does.
#
#  - legacy file vaults of alice (her home and profiles/finance: a card and
#    a login, made the way hermes made them before) move into the broker
#    when her gateway starts: same ids, labels and kinds; the legacy files
#    are gone; root's backups are 0600 in 0700; the broker's key is a new
#    one; a second start changes nothing;
#  - what alice can plant is refused, the legacy files left in place and
#    her gateway's start bounded: a vault/ that is a link to root's files,
#    a vault.key that is one, a hard-linked ciphertext, a FIFO for the
#    lock, a lock a process of hers holds (migrated once released);
#  - alice's uid cannot read the broker's state (key, ciphertext), finds
#    no card number in plain anywhere, cannot replace or chmod the socket;
#    from a shell (another process) she lists, adds and removes items, but
#    resolving a value is refused;
#  - her gateway's main process gets the values (the card number matches);
#    a child of it does not;
#  - bob's uid is refused by alice's broker;
#  - the gateway (and dashboard) units run with no core dumps.
{ pkgs, self }:
let
  inherit (pkgs) lib;
  hlib = self.lib;
  aliceHome = "${hlib.stateDir "alice"}/.hermes";
  state = "/var/lib/private/hermes-vault/alice";
  fillDir = "/run/vault-broker-fill";
in
pkgs.testers.runNixOSTest {
  name = "hyperhermes-vault-broker";

  containers.machine =
    { config, ... }:
    {
      imports = [
        self.nixosModules.core
        ../container-pam.nix
      ];

      services.hyperhermes.agents = {
        alice.uid = 1001;
        bob.uid = 1002;
      };

      systemd.tmpfiles.rules = [ "d ${fillDir} 0700 alice users - -" ];

      systemd.services = {
        # The stand-in gateway, as the unit's main process (core's preStart
        # still runs).
        hermes-agent-alice = {
          environment = {
            FILL_DIR = fillDir;
            AGENT_PY = "${./agent.py}";
          };
          serviceConfig = {
            ExecStart = lib.mkForce "${config.services.hyperhermes.package.hermesVenv}/bin/python3 ${./gateway.py}";
            Restart = lib.mkForce "no";
          };
        };
        hermes-agent-bob.serviceConfig = {
          Type = lib.mkForce "oneshot";
          ExecStart = lib.mkForce "${pkgs.coreutils}/bin/true";
          Restart = lib.mkForce "no";
        };
      }
      // lib.genAttrs [
        "hermes-dashboard-alice"
        "hermes-dashboard-bob"
        "hermes-python-venv-alice"
        "hermes-python-venv-bob"
      ] (_: { enable = false; });
    };

  testScript =
    { containers, ... }:
    let
      py = "${containers.machine.services.hyperhermes.package.hermesVenv}/bin/python3";
      as = user: "runuser -u ${user} -- env HERMES_HOME=${aliceHome} ${py} ${./agent.py}";
    in
    ''
      import hashlib
      import json

      def agent(user, *args):
          cmd = "${as "alice"}" if user == "alice" else "${as "bob"}"
          out = machine.succeed(cmd + " " + " ".join(f"'{a}'" for a in args))
          return json.loads(out.strip().splitlines()[-1])

      def fill(handle, home):
          machine.succeed(f"rm -f ${fillDir}/result; echo '{handle} {home}' > ${fillDir}/request")
          machine.wait_until_succeeds("test -f ${fillDir}/result", timeout=30)
          return machine.succeed("cat ${fillDir}/result").strip()

      card_digest = hashlib.sha256(b"4111111111111111").hexdigest()
      finance = "${aliceHome}/profiles/finance"

      start_all()
      machine.wait_for_unit("hermes-agent-alice.service")
      machine.wait_for_unit("hermes-vault-alice.socket")

      with subtest("legacy vaults move into the broker, ids kept, backed up, legacy files gone"):
          machine.succeed("systemctl stop hermes-agent-alice")
          machine.succeed(f"runuser -u alice -- mkdir -p {finance} ${aliceHome}/profiles/evil")
          card = agent("alice", "legacy", "${aliceHome}", "payment", "Nomad card")["id"]
          login = agent("alice", "legacy", "${aliceHome}", "login", "Shop login")["id"]
          fcard = agent("alice", "legacy", finance, "payment", "Finance card")["id"]
          old_key = machine.succeed("cat ${aliceHome}/vault/vault.key").strip()
          # a planted link to root's files: never followed
          machine.succeed("install -d -m 700 /root/target && echo keep > /root/target/vault.key && cp ${aliceHome}/vault/vault.json.enc /root/target/")
          machine.succeed("runuser -u alice -- ln -s /root/target ${aliceHome}/profiles/evil/vault")
          # file-level tricks, each in a profile of its own: a key that is a link to root's file, a
          # hard-linked ciphertext, a FIFO for the lock, a lock a process of alice holds
          tricks = {}
          for p in ("filelink", "hardlink", "fifo", "held"):
              machine.succeed(f"runuser -u alice -- mkdir -p ${aliceHome}/profiles/{p}")
              tricks[p] = agent("alice", "legacy", f"${aliceHome}/profiles/{p}", "payment", p)["id"]
          machine.succeed("echo keep > /root/target/other.key")
          machine.succeed("runuser -u alice -- ln -sf /root/target/other.key ${aliceHome}/profiles/filelink/vault/vault.key")
          machine.succeed("runuser -u alice -- ln ${aliceHome}/profiles/hardlink/vault/vault.json.enc ${aliceHome}/profiles/hardlink/copy")
          machine.succeed("runuser -u alice -- sh -c 'rm ${aliceHome}/profiles/fifo/vault/.vault.lock && mkfifo ${aliceHome}/profiles/fifo/vault/.vault.lock'")
          machine.succeed("systemd-run --unit=alice-holds-lock -p User=alice ${pkgs.util-linux}/bin/flock -x ${aliceHome}/profiles/held/vault/.vault.lock ${pkgs.coreutils}/bin/sleep 600")
          machine.wait_until_succeeds("${pkgs.util-linux}/bin/lslocks | grep -q flock", timeout=30)
          machine.succeed("timeout 90 systemctl start hermes-agent-alice")
          machine.wait_for_unit("hermes-agent-alice.service")
          print(machine.succeed("journalctl -u hermes-vault-migrate-alice -o cat"))
          items = agent("alice", "list", "${aliceHome}")
          assert sorted((i["id"], i["kind"], i["label"]) for i in items) == sorted(
              [(card, "payment", "Nomad card"), (login, "login", "Shop login")]), items
          assert [i["id"] for i in agent("alice", "list", finance)] == [fcard]
          machine.fail("test -e ${aliceHome}/vault/vault.json.enc")
          machine.fail("test -e ${aliceHome}/vault/vault.key")
          machine.fail(f"test -e {finance}/vault/vault.json.enc")
          backups = machine.succeed("find /root/hermes-vault-backup -type f -printf '%m %u %p\\n'").strip().splitlines()
          print(backups)
          # home and finance: key, ciphertext and their digest each; nothing of the refused ones
          assert len(backups) == 6 and all(b.startswith("600 root ") for b in backups), backups
          assert machine.succeed("find /root/hermes-vault-backup -type d -printf '%m\\n' | sort -u").split() == ["700"]
          new_key = machine.succeed("cat ${state}/home/vault/vault.key").strip()
          assert new_key != old_key
          # the planted link: root's files untouched, nothing of them backed up
          assert machine.succeed("cat /root/target/vault.key").strip() == "keep"
          machine.succeed("test -f /root/target/vault.json.enc")
          migrate_log = machine.succeed("journalctl -u hermes-vault-migrate-alice -o cat")
          assert "'profiles/evil': NOT migrated" in migrate_log, migrate_log
          # the tricks: refused, legacy files left in place, root's file untouched, the start bounded
          assert "'profiles/filelink': NOT migrated: vault.key: cannot open without following a link" in migrate_log
          assert "'profiles/hardlink': NOT migrated: vault.json.enc: not a plain file" in migrate_log
          assert "'profiles/fifo': NOT migrated: .vault.lock is not a plain file" in migrate_log
          assert "'profiles/held': NOT migrated: a process of the agent holds the vault lock" in migrate_log
          for p in ("filelink", "hardlink", "fifo", "held"):
              machine.succeed(f"test -e ${aliceHome}/profiles/{p}/vault/vault.json.enc")
              assert agent("alice", "list", f"${aliceHome}/profiles/{p}") == []
          assert machine.succeed("cat /root/target/other.key").strip() == "keep"
          machine.succeed("systemctl stop alice-holds-lock")
          # again (the lock released): held migrates now; the rest stays refused; nothing lost
          machine.succeed("systemctl restart hermes-agent-alice")
          machine.wait_for_unit("hermes-agent-alice.service")
          assert len(agent("alice", "list", "${aliceHome}")) == 2
          assert [i["id"] for i in agent("alice", "list", "${aliceHome}/profiles/held")] == [tricks["held"]]
          machine.fail("test -e ${aliceHome}/profiles/held/vault/vault.json.enc")

      with subtest("alice's uid cannot read the vault"):
          machine.fail("runuser -u alice -- ls /var/lib/private/hermes-vault")
          machine.fail("runuser -u alice -- cat ${state}/home/vault/vault.key")
          machine.fail("runuser -u alice -- cat ${state}/home/vault/vault.json.enc")
          found = machine.succeed("runuser -u alice -- grep -rls -D skip 4111111111111111 /var/lib/hermes /run/hermes-vault /run/user /tmp /var/tmp /home /root || true").strip()
          assert found == "", found
          machine.fail("grep -rqs -D skip 4111111111111111 /var/lib/private/hermes-vault /var/lib/hermes")
          assert machine.succeed("stat -c '%U %a' /run/hermes-vault /run/hermes-vault/alice.sock /run/hermes-vault/alice.on").split() == [
              "root", "755", "root", "666", "root", "644"]
          machine.fail("runuser -u alice -- chmod 600 /run/hermes-vault/alice.sock")
          machine.fail("runuser -u alice -- rm -f /run/hermes-vault/alice.on")
          machine.fail("runuser -u alice -- touch /run/hermes-vault/x")

      with subtest("from a shell alice lists, adds and removes, but resolving is refused"):
          refused = agent("alice", "resolve", "${aliceHome}", card)
          assert "values go only to the agent's gateway or dashboard" in refused.get("error", ""), refused
          refused = agent("alice", "resolve", "${aliceHome}", login)
          assert "LEAKED" not in refused, refused
          added = agent("alice", "add", "${aliceHome}")["id"]
          assert agent("alice", "remove", "${aliceHome}", added) == {"removed": True}
          raw = agent("alice", "raw", "/run/hermes-vault/alice.sock", json.dumps({"op": "key", "home": "${aliceHome}"}))
          assert raw == {"ok": False, "error": "unknown operation"}, raw
          assert "REFUSED resolve" in machine.succeed("journalctl -u hermes-vault-alice -o cat")

      with subtest("the gateway's main process gets the values, a child of it does not"):
          assert fill(card, "${aliceHome}") == f"ok {card_digest}"
          assert fill(fcard, finance) == f"ok {card_digest}"
          assert fill(login, "${aliceHome}").startswith("ok ")
          # a process the gateway starts (a terminal command): another pid
          out = fill(f"child:{card}", "${aliceHome}")
          assert out.startswith("child ") and "values go only to the agent's gateway" in out, out
          journal = machine.succeed("journalctl -u hermes-vault-alice -o cat")
          assert f"resolve {card} kind=payment label='Nomad card' home=home unit=hermes-agent-alice.service" in journal, journal
          assert "4111111111111111" not in machine.succeed("journalctl -o cat")

      with subtest("quotas and deadlines: an oversized legacy record is not imported, a slow client is cut off"):
          machine.succeed("systemctl stop hermes-agent-alice")
          machine.succeed("runuser -u alice -- mkdir -p ${aliceHome}/profiles/huge")
          agent("alice", "legacy", "${aliceHome}/profiles/huge", "payment", "x" * 20000)
          machine.succeed("systemctl start hermes-agent-alice")
          machine.wait_for_unit("hermes-agent-alice.service")
          assert "'profiles/huge': NOT migrated: the broker lacks 1 of 1 items" in machine.succeed(
              "journalctl -u hermes-vault-migrate-alice -o cat")
          machine.succeed("test -e ${aliceHome}/profiles/huge/vault/vault.json.enc")
          slow = machine.succeed(
              "runuser -u alice -- ${pkgs.python3}/bin/python3 -c \"import socket,time; s=socket.socket(socket.AF_UNIX); "
              "s.connect('/run/hermes-vault/alice.sock'); s.sendall(b'{'); t=time.time(); d=s.recv(9999); "
              "print(round(time.time()-t), d.decode())\"").strip()
          seconds, reply = slow.split(" ", 1)
          assert int(seconds) <= 12 and json.loads(reply)["ok"] is False, slow

      with subtest("bob's uid is refused by alice's broker"):
          out = agent("bob", "raw", "/run/hermes-vault/alice.sock",
                      json.dumps({"op": "list_items", "home": "${aliceHome}"}))
          assert out == {"ok": False, "error": "this vault belongs to another account"}, out

      with subtest("no core dumps of the gateway or dashboard"):
          # (the dashboard unit is off here; it gets the same setting)
          for unit in ("hermes-agent-alice", "hermes-vault-alice"):
              assert machine.succeed(f"systemctl show -P LimitCORE {unit}").strip() == "0", unit
          pid = machine.succeed("systemctl show -P MainPID hermes-agent-alice").strip()
          assert machine.succeed(f"grep 'Max core file size' /proc/{pid}/limits").split()[4:6] == ["0", "0"]
    '';
}
