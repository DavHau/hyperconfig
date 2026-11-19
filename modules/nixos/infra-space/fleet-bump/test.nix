# ./fleet-bump.sh in a VM, offline: a local "nixpkgs" git repository
# with a channel branch, a toy hyperconfig in a local bare repository
# (main) whose fleetJobs.nightly has two jobs, `good` and `bad`; bad fails
# while the nixpkgs rev lists it as broken.
#   1. red: flake.nix's nixpkgs.url moved to the channel, the lock to its
#      tip; auto/nixpkgs pushed (bump commit + verdict commit), main
#      untouched; status.json result red, jobs {good: ok, bad: fail}, the
#      error line in errors.bad and in the commit message; exit 1; good's
#      out-link rooted under /nix/var/nix/gcroots/fleet-bump.
#   2. a held lock: exit 75 (unit success), nothing written.
#   3. green after the channel moves on, with a killed run's leftover
#      work tree: auto/nixpkgs force-pushed, exit 0, only `keep` runs left.
#   4. error: an unreachable repository -> result error, exit 2, status
#      written, the branch untouched; an error run evicts no roots.
#   5. downgrade: the channel at a nixpkgs older than main's lock ->
#      result error, nothing pushed.
#   6. a run waits while the agent's bump (a stand-in unit) is active;
#      stopped while waiting it still writes status (error, killed); past
#      waitMaxSec it gives up (error).
#   7. roots of the newest `keep` building runs only.
#   8. --cadence weekly: status-weekly.json, branch auto/nixpkgs-weekly;
#      `--cadence` without a value: usage, exit 2 (no loop).
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "fleet-bump";

  nodes.machine =
    { ... }:
    {
      imports = [ ./default.nix ];
      virtualisation.memorySize = 2048;
      virtualisation.writableStore = true;
      nix.settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        flake-registry = "";
        substituters = pkgs.lib.mkForce [ ];
      };
      networking.hostName = "som";
      users.users.infra = {
        isNormalUser = true;
        group = "infra";
      };
      users.groups.infra = { };
      environment.systemPackages = [ pkgs.git pkgs.jq ];
      infraSpace.fleetBump = {
        enable = true;
        repo = "/srv/hyperconfig.git";
        nixpkgsUrl = "git+file:///srv/nixpkgs?ref=nixos-unstable";
        keep = 2;
        waitFor = [ "blocker.service" ];
        waitMaxSec = 40;
      };
      # stands in for the agent's bump: a oneshot, `activating` while it
      # runs, as nixpkgs-bump.service (`is-active` would say inactive)
      systemd.services.blocker.serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        TimeoutStartSec = "infinity";
      };
    };

  testScript = ''
    import json

    def infra(cmd):
        return machine.succeed(f"su - infra -c {json.dumps(cmd)}")

    def run_unit():
        machine.execute("systemctl start fleet-bump.service")
        machine.wait_until_succeeds("systemctl show -p ActiveState --value fleet-bump.service | grep -qx -e inactive -e failed")
        return int(machine.succeed("systemctl show -p ExecMainStatus --value fleet-bump.service").strip())

    def status():
        return json.loads(machine.succeed("cat /var/lib/fleet-bump/status.json"))

    def nixpkgs_commit(broken, msg):
        infra(f"cd /srv/nixpkgs && printf '{{ outputs = _: {{ broken = [ {broken} ]; }}; }} # {msg}\\n' > flake.nix "
              f"&& git add flake.nix && git commit -qm '{msg}' && git rev-parse HEAD")
        return infra("git -C /srv/nixpkgs rev-parse HEAD").strip()

    machine.wait_for_unit("multi-user.target")
    machine.succeed("install -d -o infra -g infra /srv")
    infra("git config --global user.name t && git config --global user.email t@t && git config --global init.defaultBranch main")

    with subtest("setup: fake nixpkgs and a toy hyperconfig"):
        infra("mkdir /srv/nixpkgs && cd /srv/nixpkgs && git init -q && git checkout -qb nixos-unstable")
        rev1 = nixpkgs_commit('"bad"', "rev1")
        infra("git -C /srv/nixpkgs branch old-channel")
        infra("git init -q --bare /srv/hyperconfig.git && git clone -q /srv/hyperconfig.git /tmp/hc")
        machine.succeed("""cat > /tmp/flake.nix <<'EOF'
    {
      inputs = {
        nixpkgs.url = "git+file:///srv/nixpkgs?ref=old-channel";
      };
      outputs = { nixpkgs, ... }:
        let
          job = name: derivation {
            inherit name;
            system = "x86_64-linux";
            builder = "/bin/sh";
            rev = nixpkgs.rev;
            args = [ "-c" (if builtins.elem name nixpkgs.broken
              then "echo 'error: job bad is broken on this nixpkgs' >&2; exit 1"
              else "echo ok > $out") ];
          };
        in {
          fleetJobs.nightly = { good = job "good"; bad = job "bad"; };
          fleetJobs.weekly = { slow = job "slow"; };
        };
    }
    EOF
    install -o infra -g infra -m 0644 /tmp/flake.nix /tmp/hc/flake.nix""")
        infra("cd /tmp/hc && git add -A && nix flake lock && git add -A && git commit -qm init && git push -q origin HEAD:main")
        main0 = infra("git -C /srv/hyperconfig.git rev-parse main").strip()
        rev2 = nixpkgs_commit('"bad"', "rev2")

    with subtest("red: branch pushed, main untouched, status red"):
        code = run_unit()
        assert code == 1, code
        # red is a verdict, not a failed unit (no fleet-unit-failed alert)
        machine.succeed("systemctl show -p Result --value fleet-bump.service | grep -qx success")
        s = status()
        print(json.dumps(s, indent=1))
        assert s["result"] == "red", s
        assert s["jobs"] == {"good": "ok", "bad": "fail"}, s["jobs"]
        assert s["nixpkgs_rev"] == rev2 and s["old_nixpkgs_rev"] == rev1, s
        assert s["channel"] == "nixos-unstable", s
        assert any("job bad is broken" in l for l in s["errors"]["bad"]), s["errors"]
        for k in ("started", "finished", "branch_commit"):
            assert s[k], k
        assert infra("git -C /srv/hyperconfig.git rev-parse main").strip() == main0
        tip = infra("git -C /srv/hyperconfig.git rev-parse auto/nixpkgs").strip()
        assert tip == s["branch_commit"], (tip, s)
        msg = infra("git -C /srv/hyperconfig.git log -1 --format=%B auto/nixpkgs")
        assert "result: red" in msg and "job bad: fail" in msg and "job good: ok" in msg, msg
        assert "job bad is broken" in msg, msg
        trailer = [l for l in msg.splitlines() if l.startswith("Fleet-Bump-Status: ")][0]
        assert json.loads(trailer.split(": ", 1)[1])["jobs"]["bad"] == "fail", trailer
        # the candidate: main + the bump, nothing else
        cand = s["candidate_commit"]
        assert infra(f"git -C /srv/hyperconfig.git rev-parse {cand}^").strip() == main0
        assert infra("git -C /srv/hyperconfig.git rev-parse auto/nixpkgs^").strip() == cand
        changed = infra(f"git -C /srv/hyperconfig.git diff --name-only {main0} {cand}").split()
        assert sorted(changed) == ["flake.lock", "flake.nix"], changed
        flake = infra(f"git -C /srv/hyperconfig.git show {cand}:flake.nix")
        assert 'nixpkgs.url = "git+file:///srv/nixpkgs?ref=nixos-unstable";' in flake, flake
        # good's build is a GC root; it survives a collection
        out = machine.succeed(f"readlink /nix/var/nix/gcroots/fleet-bump/{s['run']}/good").strip()
        machine.succeed("nix-collect-garbage >/dev/null 2>&1")
        machine.succeed(f"test -e {out}")
        machine.succeed(f"test -s /var/lib/fleet-bump/runs/{s['run']}/logs/bad.log")
        red_run = s["run"]

    with subtest("a held lock: exit 75, nothing written"):
        before = machine.succeed("cat /var/lib/fleet-bump/status.json")
        machine.succeed("su infra -s /bin/sh -c 'flock /var/lib/fleet-bump/lock sleep 30' >/dev/null 2>&1 &")
        machine.wait_until_succeeds("pgrep -f '[f]lock /var/lib/fleet-bump/lock'")
        code = run_unit()
        assert code == 75, code
        machine.succeed("systemctl show -p Result --value fleet-bump.service | grep -qx success")
        assert machine.succeed("cat /var/lib/fleet-bump/status.json") == before
        machine.succeed("pkill -f '[f]lock /var/lib/fleet-bump/lock'")
        machine.wait_until_fails("pgrep -f '[f]lock /var/lib/fleet-bump/lock'")

    with subtest("green after the channel moves, over a killed run's leftovers"):
        rev3 = nixpkgs_commit("", "rev3")
        infra("mkdir -p /var/lib/fleet-bump/work && cd /var/lib/fleet-bump/work && git init -q && echo junk > flake.nix")
        code = run_unit()
        assert code == 0, code
        s = status()
        assert s["result"] == "green" and s["jobs"] == {"good": "ok", "bad": "ok"}, s
        assert s["nixpkgs_rev"] == rev3 and s["errors"] == {}, s
        assert infra("git -C /srv/hyperconfig.git rev-parse auto/nixpkgs").strip() == s["branch_commit"]
        assert infra("git -C /srv/hyperconfig.git rev-parse main").strip() == main0
        machine.succeed("systemctl show -p Result --value fleet-bump.service | grep -qx success")
        green_run = s["run"]

    with subtest("error: the repository unreachable"):
        green_tip = s["branch_commit"]
        machine.succeed("mv /srv/hyperconfig.git /srv/away.git")
        code = run_unit()
        machine.succeed("mv /srv/away.git /srv/hyperconfig.git")
        assert code == 2, code
        s = status()
        assert s["result"] == "error" and "fetching main" in s["error"], s
        assert s["branch_commit"] == "", s
        assert infra("git -C /srv/hyperconfig.git rev-parse auto/nixpkgs").strip() == green_tip
        # keep = 2: logs of the last two runs; the error run built nothing,
        # so it evicts no roots
        assert machine.succeed("ls /var/lib/fleet-bump/runs").split() == [green_run, s["run"]]
        assert machine.succeed("ls /nix/var/nix/gcroots/fleet-bump").split() == [red_run, green_run]

    with subtest("downgrade: a channel older than main's nixpkgs is refused"):
        machine.succeed("systemctl reset-failed fleet-bump.service")
        tip_before = infra("git -C /srv/hyperconfig.git rev-parse auto/nixpkgs").strip()
        chan = infra("git -C /srv/nixpkgs rev-parse nixos-unstable").strip()
        # a branch off rev1 (main's lock) with a commit dated long before it
        old = infra(f"cd /srv/nixpkgs && git checkout -q -b older {rev1} && echo '# older' >> flake.nix "
                    "&& git add flake.nix && GIT_COMMITTER_DATE='2001-01-01T00:00:00Z' "
                    "GIT_AUTHOR_DATE='2001-01-01T00:00:00Z' git commit -qm older && git rev-parse HEAD").strip()
        infra(f"git -C /srv/nixpkgs branch -f nixos-unstable {old}")
        code = run_unit()
        assert code == 2, code
        s = status()
        print(s["error"])
        assert s["result"] == "error" and "refusing a downgrade" in s["error"], s
        assert s["nixpkgs_rev"] == old and s["branch_commit"] == "", s
        assert infra("git -C /srv/hyperconfig.git rev-parse auto/nixpkgs").strip() == tip_before
        assert infra("git -C /srv/hyperconfig.git rev-parse main").strip() == main0
        infra(f"cd /srv/nixpkgs && git branch -f nixos-unstable {chan} && git checkout -q nixos-unstable")
        machine.succeed("systemctl reset-failed fleet-bump.service")

    with subtest("waits while the agent's bump runs; killed while waiting still reports"):
        machine.succeed("systemctl start --no-block blocker.service")
        machine.wait_until_succeeds("systemctl show -p ActiveState --value blocker.service | grep -qx activating")
        machine.succeed("systemctl start --no-block fleet-bump.service")
        machine.sleep(3)
        machine.succeed("systemctl show -p ActiveState --value fleet-bump.service | grep -qx activating")
        before = status()["run"]
        machine.succeed("systemctl stop fleet-bump.service")
        s = status()
        assert s["run"] != before and s["result"] == "error" and "killed by SIGTERM" in s["error"], s
        machine.succeed("systemctl reset-failed fleet-bump.service")

    with subtest("gives up past waitMaxSec"):
        code = run_unit()
        assert code == 2, code
        s = status()
        assert s["result"] == "error" and "still active after" in s["error"], s
        machine.succeed("systemctl stop blocker.service")
        machine.succeed("systemctl reset-failed fleet-bump.service")

    with subtest("roots: a third building run evicts the oldest"):
        code = run_unit()
        assert code == 0, code
        s = status()
        assert machine.succeed("ls /nix/var/nix/gcroots/fleet-bump").split() == [green_run, s["run"]]

    with subtest("weekly: its own status file and branch"):
        nightly = machine.succeed("cat /var/lib/fleet-bump/status.json")
        infra("fleet-bump --cadence weekly")
        w = json.loads(machine.succeed("cat /var/lib/fleet-bump/status-weekly.json"))
        assert w["result"] == "green" and w["jobs"] == {"slow": "ok"} and w["branch"] == "auto/nixpkgs-weekly", w
        assert infra("git -C /srv/hyperconfig.git rev-parse auto/nixpkgs-weekly").strip() == w["branch_commit"]
        assert machine.succeed("cat /var/lib/fleet-bump/status.json") == nightly

    with subtest("--cadence without a value: usage, exit 2"):
        code, out = machine.execute("timeout 20 su - infra -c 'fleet-bump --cadence' 2>&1")
        assert code == 2, (code, out)
        assert "usage:" in out, out
  '';
}
