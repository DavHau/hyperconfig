# The secrets mirror (./clan-secrets-mirror.nix) against a local bare repo
# standing in for GitHub: an empty remote is fine, then the first clone, a
# fast-forward, a force push (old tip kept under refs/backup/, main follows)
# and an unreachable remote (unit fails, mirror untouched).
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "clan-secrets-mirror";

  nodes.machine = { lib, ... }: {
    imports = [ ./clan-secrets-mirror.nix ];
    # What clan would provide: the generator declaration is ignored here,
    # and a file:// remote needs no deploy key.
    options.clan.core.vars.generators = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
    };
    config = {
      clan.core.vars.generators.clan-secrets-pull.files.id_ed25519.path = "/nonexistent";
      clanSecretsMirror.url = "file:///srv/remote.git";
      programs.git = {
        enable = true;
        config.user = { name = "test"; email = "test@test"; };
      };
    };
  };

  testScript = ''
    import re

    def mirror_main():
        return machine.succeed("git -C /var/lib/clan-secrets rev-parse refs/heads/main").strip()

    def push(*commands):
        machine.succeed("cd /srv/work && " + " && ".join(commands))
        return machine.succeed("git -C /srv/remote.git rev-parse refs/heads/main").strip()

    machine.wait_for_unit("clan-secrets-mirror.timer")
    # Runs are started by hand from here on.
    machine.succeed("systemctl stop clan-secrets-mirror.timer")
    machine.succeed(
        "git init --quiet --bare --initial-branch=main /srv/remote.git",
        "git init --quiet --initial-branch=main /srv/work",
        "git -C /srv/work remote add origin /srv/remote.git",
    )

    with subtest("an empty remote is no failure"):
        machine.succeed("systemctl start clan-secrets-mirror.service")
        machine.fail("git -C /var/lib/clan-secrets rev-parse --verify --quiet refs/heads/main")
        assert machine.succeed("stat -c %a:%U /var/lib/clan-secrets").strip() == "700:root"

    with subtest("first clone"):
        first = push("echo 1 > f", "git add f", "git commit -qm 1", "git push -q origin main")
        machine.succeed("systemctl start clan-secrets-mirror.service")
        assert mirror_main() == first
        machine.succeed("git clone -q /var/lib/clan-secrets /tmp/clone && test \"$(cat /tmp/clone/f)\" = 1")

    with subtest("fast-forward"):
        second = push("echo 2 > f", "git commit -qam 2", "git push -q origin main")
        machine.succeed("systemctl start clan-secrets-mirror.service")
        assert mirror_main() == second
        machine.fail("git -C /var/lib/clan-secrets for-each-ref refs/backup | grep -q .")

    with subtest("a force push is followed, the old tip kept"):
        rewritten = push("git commit -q --amend -m 2b", "git push -qf origin main")
        machine.succeed("systemctl start clan-secrets-mirror.service")
        assert mirror_main() == rewritten
        backups = machine.succeed(
            "git -C /var/lib/clan-secrets for-each-ref --format='%(refname) %(objectname)' refs/backup"
        ).strip().splitlines()
        assert len(backups) == 1, backups
        name, target = backups[0].split()
        assert target == second, backups
        assert re.fullmatch(r"refs/backup/[0-9]{8}T[0-9]{6}Z", name), name

    with subtest("an unreachable remote fails the unit, the mirror stays"):
        machine.succeed("mv /srv/remote.git /srv/gone.git")
        machine.fail("systemctl start clan-secrets-mirror.service")
        machine.succeed("systemctl is-failed clan-secrets-mirror.service")
        assert mirror_main() == rewritten
        machine.succeed("mv /srv/gone.git /srv/remote.git")
        # Starts this close together hit systemd's start limit; the timer's
        # never do.
        machine.succeed("systemctl reset-failed clan-secrets-mirror.service")
        machine.succeed("systemctl start clan-secrets-mirror.service")
  '';
}
