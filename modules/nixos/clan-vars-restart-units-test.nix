# restartUnits of clan vars with the age backend
# (./clan-vars-restart-units.nix) in real switches. clan's vars options
# and its setupSecrets activation snippet are stubbed: the stub writes the
# "decrypted" secret from `testSecret.*`, which the specialisations change.
# A service reading the secret only at start (demo) and a template
# instance (tpl@a) name it in restartUnits; a second var names a unit that
# doesn't exist. Covered: boot and an unchanged switch restart nothing; a
# changed secret restarts both units, which then see the new value; the
# first switch without recorded state only records; a secret that goes
# missing restarts nothing (and its return does); a read-only state dir
# still restarts and never fails the switch.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "clan-vars-restart-units";

  nodes.machine =
    { config, lib, ... }:
    let
      cfg = config.testSecret;
      secret = restartUnits: path: {
        secret = true;
        deploy = true;
        neededFor = "services";
        inherit path restartUnits;
      };
    in
    {
      imports = [ ./clan-vars-restart-units.nix ];

      # What clan provides.
      options.clan.core.vars = {
        generators = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
        settings = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
      };
      options.testSecret = {
        value = lib.mkOption {
          type = lib.types.str;
          default = "one";
        };
        present = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
      };

      config = {
        clan.core.vars.settings.secretStore = "age";
        clan.core.vars.generators.demo.files.token = secret [
          "demo.service"
          "tpl@a.service"
          "nonexistent.service"
        ] "/run/secrets/demo/token";
        # Never deployed: its file stays missing.
        clan.core.vars.generators.ghost.files.key = secret [ "demo.service" ] "/run/secrets/ghost/key";
        # Not a secret: ignored.
        clan.core.vars.generators.pub.files.pub = (secret [ "demo.service" ] "/nonexistent") // {
          secret = false;
        };

        # clan's age setupSecrets: decrypt into /run/secrets.
        system.activationScripts.setupSecrets = lib.stringAfter [ "specialfs" "users" "groups" ] (
          ''
            mkdir -p /run/secrets/demo
          ''
          + (
            if cfg.present then
              ''
                printf '%s\n' ${lib.escapeShellArg cfg.value} > /run/secrets/demo/token.tmp
                mv /run/secrets/demo/token.tmp /run/secrets/demo/token
              ''
            else
              ''
                rm -f /run/secrets/demo/token
              ''
          )
        ) // {
          # clan's does too (and decrypts for real even then).
          supportsDryActivation = true;
        };

        systemd.services.demo = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = pkgs.writeShellScript "demo" ''
            cp /run/secrets/demo/token /run/demo-seen
            exec sleep infinity
          '';
        };
        systemd.services."tpl@" = {
          serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        };
        systemd.targets.multi-user.wants = [ "tpl@a.service" ];

        specialisation.two.configuration.testSecret.value = "two";
        specialisation.gone.configuration.testSecret.present = false;
      };
    };

  testScript =
    { nodes, ... }:
    let
      inherit (nodes.machine) warnings;
      table = builtins.head (
        builtins.match ".*(/nix/store/[a-z0-9]+-clan-vars-restart-units).*" nodes.machine.system.activationScripts.clanVarsRestartUnits.text
      );
    in
    ''
      import json

      warnings = json.loads(${builtins.toJSON (builtins.toJSON warnings)})
      with subtest("an unknown unit in restartUnits warns at eval"):
          hits = [w for w in warnings if "nonexistent.service" in w]
          assert len(hits) == 1 and "demo/token" in hits[0], warnings
          # Neither the unknown unit nor the non-secret makes it into the table.
          table = machine.succeed("cat ${table}")
          assert "nonexistent" not in table and "/nonexistent" not in table, table
          assert "tpl@a.service" in table, table

      def ids():
          return {
              u: machine.succeed(f"systemctl show -P InvocationID {u}").strip()
              for u in ("demo.service", "tpl@a.service")
          }

      def seen():
          return machine.succeed("cat /run/demo-seen").strip()

      def switch(spec):
          top = "/run/booted-system" + (f"/specialisation/{spec}" if spec else "")
          rc, out = machine.execute(f"{top}/bin/switch-to-configuration test 2>&1")
          print(out)
          assert rc == 0, f"switch to {spec or 'base'} failed ({rc})"
          return out

      def expect(before, restarted):
          after = ids()
          for u in before:
              if restarted:
                  assert after[u] != before[u], f"{u} was not restarted"
              else:
                  assert after[u] == before[u], f"{u} was restarted"
          machine.succeed("systemctl is-active demo.service tpl@a.service")
          return after

      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("demo.service")
      machine.wait_for_unit("tpl@a.service")

      with subtest("boot records the hashes, state is root-only"):
          assert seen() == "one"
          machine.succeed("test -s /run/clan-vars-restart-units/.salt")
          machine.succeed("[ $(stat -c %a /run/clan-vars-restart-units) = 700 ]")
          # demo/token and ghost/key; the missing one is recorded as absent.
          machine.succeed("[ $(ls /run/clan-vars-restart-units | wc -l) = 2 ]")
          machine.succeed("grep -qx absent /run/clan-vars-restart-units/*")

      with subtest("unchanged secret: no restart"):
          i = ids()
          out = switch(None)
          assert "changed, restarting" not in out, out
          expect(i, restarted=False)

      with subtest("changed secret: both units restart and see the new value"):
          i = ids()
          out = switch("two")
          assert "/run/secrets/demo/token changed, restarting: demo.service tpl@a.service" in out, out
          expect(i, restarted=True)
          assert seen() == "two"

      with subtest("same secret again: no restart"):
          i = ids()
          switch("two")
          expect(i, restarted=False)

      with subtest("dry-activate: reports the restart, records nothing"):
          before = machine.succeed("cat /run/clan-vars-restart-units/* | sha256sum")
          i = ids()
          out = machine.succeed("/run/booted-system/bin/switch-to-configuration dry-activate 2>&1")
          print(out)
          assert "would restart the following units: demo.service, tpl@a.service" in out, out
          assert machine.succeed("cat /run/clan-vars-restart-units/* | sha256sum") == before
          expect(i, restarted=False)
          i = ids()
          switch("two")
          expect(i, restarted=False)

      with subtest("no recorded state (first switch with the module): records only"):
          machine.succeed("rm -rf /run/clan-vars-restart-units")
          i = ids()
          switch(None)
          expect(i, restarted=False)
          assert seen() == "two"
          machine.succeed("test -s /run/clan-vars-restart-units/.salt")
          i = ids()
          switch("two")
          expect(i, restarted=True)
          assert seen() == "two"

      with subtest("a secret that goes missing restarts nothing, its return does"):
          i = ids()
          out = switch("gone")
          machine.fail("test -e /run/secrets/demo/token")
          expect(i, restarted=False)
          i = ids()
          switch("two")
          expect(i, restarted=True)

      with subtest("read-only state dir: still restarts, the switch succeeds"):
          machine.succeed(
              "mount --bind /run/clan-vars-restart-units /run/clan-vars-restart-units",
              "mount -o remount,bind,ro /run/clan-vars-restart-units",
          )
          i = ids()
          out = switch(None)
          assert "clan-vars-restart-units: failed" in out, out
          assert "Activation script snippet" not in out, out
          expect(i, restarted=True)
          assert seen() == "one"
          machine.succeed("umount /run/clan-vars-restart-units")

      with subtest("state is a file, not a dir: re-created, the switch succeeds"):
          machine.succeed("rm -rf /run/clan-vars-restart-units && touch /run/clan-vars-restart-units")
          i = ids()
          switch("two")
          expect(i, restarted=False)
          machine.succeed("test -s /run/clan-vars-restart-units/.salt")

      with subtest("no unit failed along the way"):
          machine.fail("systemctl --failed --no-legend | grep .")
    '';
}
