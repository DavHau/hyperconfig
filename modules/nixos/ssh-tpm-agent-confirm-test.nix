# End-to-end regression test for the ssh-tpm-agent confirm-grant cache.
#
# The grant model: the confirm dialog offers the peer's process ancestry and
# the user trusts ONE process; the grant covers that process and all of its
# descendants, keyed by (pid, starttime). This reproduces the omp-inside-sbox
# case: requests come from short-lived ssh processes inside a sandbox (own
# user+pid namespace), so
#   - trusting the requesting process itself silences nothing (fresh pid each
#     time), while
#   - trusting an ancestor (the sandbox shell) silences every later request
#     from that subtree — including across the namespace boundary, because the
#     agent only reads world-readable /proc/<pid>/stat, and
#   - a second sandbox (different ancestor) prompts again.
#
# A scripted SSH_ASKPASS records every confirm dialog; we assert the count.
{ pkgs }:
let
  sshTpmAgent = import ./ssh-tpm-agent-package.nix { inherit pkgs; };

  # Records every confirm dialog and grants per /tmp/grant-mode:
  #   self  -> sticky grant on the requesting process itself (choices line 1)
  #   shell -> sticky grant on the nearest bash ancestor (the loop shell)
  # PIN prompts (no SSH_ASKPASS_PROMPT) return an empty PIN for the no-PIN test
  # key and are not counted.
  askpass = pkgs.writeShellScript "test-askpass" ''
    if [ "$SSH_ASKPASS_PROMPT" = choice ]; then
      echo confirm >> /tmp/prompts
      case "$(${pkgs.coreutils}/bin/cat /tmp/grant-mode)" in
        self)  pid="$(printf '%s\n' "$SSH_TPM_CHOICES" | ${pkgs.gnused}/bin/sed -n '1s/ .*//p')" ;;
        shell) pid="$(printf '%s\n' "$SSH_TPM_CHOICES" | ${pkgs.gawk}/bin/awk '$2 == "bash" { print $1; exit }')" ;;
        *)     pid="" ;;
      esac
      if [ -n "$pid" ]; then
        echo "session $pid"
      else
        echo deny
      fi
    else
      echo ""
    fi
  '';

  genKey = pkgs.writeShellScript "gen-key" ''
    set -e
    mkdir -p /home/alice/.ssh
    SSH_ASKPASS=${askpass} SSH_ASKPASS_REQUIRE=force \
      ${sshTpmAgent}/bin/ssh-tpm-keygen -t ecdsa -f /home/alice/.ssh/id_tpm -C testkey -N "" < /dev/null
  '';

  # One detached (setsid) request, no sandbox.
  reqDetached = pkgs.writeShellScript "req-detached" ''
    SSH_AUTH_SOCK=/tmp/tpmagent.sock ${pkgs.util-linux}/bin/setsid -w \
      ${pkgs.openssh}/bin/ssh-add -T /home/alice/.ssh/id_tpm.pub
  '';

  # $1 detached requests inside ONE fresh sandbox (own pid+user namespace, like
  # sbox). Each ssh-add is setsid'd so it is its own session leader; the bash
  # running the loop is the common ancestor a "shell" grant should stick to.
  reqSandbox = pkgs.writeShellScript "req-sandbox" ''
    ${pkgs.util-linux}/bin/unshare --user --map-current-user --pid --fork --mount-proc \
      ${pkgs.bash}/bin/bash -c '
        i=0
        while [ "$i" -lt "$1" ]; do
          SSH_AUTH_SOCK=/tmp/tpmagent.sock ${pkgs.util-linux}/bin/setsid -w \
            ${pkgs.openssh}/bin/ssh-add -T /home/alice/.ssh/id_tpm.pub
          i=$((i + 1))
        done
      ' bash "$1"
  '';
in
pkgs.testers.runNixOSTest {
  name = "ssh-tpm-confirm-cache";

  nodes.machine = { config, lib, pkgs, ... }: {
    virtualisation.tpm.enable = true;
    security.tpm2.enable = true;

    users.users.alice = {
      isNormalUser = true;
      extraGroups = [ "tss" ];
    };

    environment.systemPackages = [ sshTpmAgent pkgs.openssh pkgs.util-linux ];
    boot.kernel.sysctl."user.max_user_namespaces" = lib.mkDefault 100000;

    # Force the scripts (and their closures) into the guest store.
    system.extraDependencies = [ askpass genKey reqDetached reqSandbox ];
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("test -c /dev/tpmrm0", timeout=120)

    # A TPM key with no PIN; SSH_TPM_CONFIRM_ALL gates every signature.
    machine.succeed("runuser -u alice -- ${genKey}")
    machine.succeed("test -f /home/alice/.ssh/id_tpm.tpm")
    machine.succeed("test -f /home/alice/.ssh/id_tpm.pub")

    def start_agent(grant_mode):
        machine.succeed("systemctl stop tpmagent.service || true")
        machine.succeed("systemctl reset-failed tpmagent.service || true")
        machine.succeed("rm -f /tmp/tpmagent.sock /tmp/prompts; touch /tmp/prompts; chmod 666 /tmp/prompts")
        machine.succeed(f"echo {grant_mode} > /tmp/grant-mode; chmod 644 /tmp/grant-mode")
        machine.succeed(
            "systemd-run --collect --unit=tpmagent -p User=alice "
            "--setenv=SSH_TPM_CONFIRM_ALL=1 --setenv=SSH_TPM_PROMPT=gui "
            "--setenv=SSH_ASKPASS=${askpass} --setenv=HOME=/home/alice "
            "${sshTpmAgent}/bin/ssh-tpm-agent -l /tmp/tpmagent.sock --key-dir /home/alice/.ssh -d"
        )
        machine.wait_until_succeeds("test -S /tmp/tpmagent.sock", timeout=30)

    def prompts():
        return int(machine.succeed("wc -l < /tmp/prompts").strip())

    with subtest("trusting the requester itself covers only that process"):
        start_agent("self")
        machine.succeed("runuser -u alice -- ${reqDetached}")
        n = prompts()
        assert n == 1, f"expected exactly 1 confirm prompt, got {n}"
        machine.succeed("runuser -u alice -- ${reqDetached}")
        n = prompts()
        assert n == 2, f"a new requesting pid must re-prompt, got {n} prompts"

    with subtest("trusting the sandbox shell covers later requests from it"):
        start_agent("shell")
        machine.succeed("runuser -u alice -- ${reqSandbox} 3")
        n = prompts()
        assert n == 1, f"descendants of the granted shell must be cached, got {n} prompts"

    with subtest("a second sandbox does not inherit the grant"):
        start_agent("shell")
        machine.succeed("runuser -u alice -- ${reqSandbox} 1")
        machine.succeed("runuser -u alice -- ${reqSandbox} 1")
        n = prompts()
        assert n == 2, f"distinct sandboxes must each prompt, got {n}"
  '';
}
