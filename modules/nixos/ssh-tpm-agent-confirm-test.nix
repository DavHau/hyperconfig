# End-to-end regression test for the ssh-tpm-agent confirm-grant cache.
#
# Reproduces the omp-inside-sbox failure: a process manager spawns `ssh` via
# setsid(), so each request is its own session leader. The grant key must resolve
# the *enclosing* session (peerid.resolveSession) and include the peer's pid
# namespace, so that:
#   - repeated requests from one sandbox are cached (one prompt), and
#   - two different sandboxes never share a grant (separate prompts).
#
# A scripted SSH_ASKPASS records every confirm dialog; we assert the count.
{ pkgs }:
let
  sshTpmAgent = import ./ssh-tpm-agent-package.nix { inherit pkgs; };

  # Records every confirm dialog and auto-approves "this session". PIN prompts
  # (no SSH_ASKPASS_PROMPT) return an empty PIN for the no-PIN test key and are
  # not counted.
  askpass = pkgs.writeShellScript "test-askpass" ''
    if [ "$SSH_ASKPASS_PROMPT" = choice ]; then
      echo confirm >> /tmp/prompts
      echo session
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
  # sbox). Each ssh-add is setsid'd so it is its own session leader.
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

    def start_agent():
        machine.succeed("systemctl stop tpmagent.service || true")
        machine.succeed("systemctl reset-failed tpmagent.service || true")
        machine.succeed("rm -f /tmp/tpmagent.sock /tmp/prompts; touch /tmp/prompts; chmod 666 /tmp/prompts")
        machine.succeed(
            "systemd-run --collect --unit=tpmagent -p User=alice "
            "--setenv=SSH_TPM_CONFIRM_ALL=1 --setenv=SSH_TPM_PROMPT=gui "
            "--setenv=SSH_ASKPASS=${askpass} --setenv=HOME=/home/alice "
            "${sshTpmAgent}/bin/ssh-tpm-agent -l /tmp/tpmagent.sock --key-dir /home/alice/.ssh -d"
        )
        machine.wait_until_succeeds("test -S /tmp/tpmagent.sock", timeout=30)

    def prompts():
        return int(machine.succeed("wc -l < /tmp/prompts").strip())

    with subtest("a single confirm prompts exactly once"):
        start_agent()
        machine.succeed("runuser -u alice -- ${reqDetached}")
        n = prompts()
        assert n == 1, f"expected exactly 1 confirm prompt, got {n}"

    with subtest("repeat ssh from one sandbox is cached"):
        start_agent()
        machine.succeed("runuser -u alice -- ${reqSandbox} 2")
        n = prompts()
        assert n == 1, f"second detached ssh in the same sandbox must be cached, got {n} prompts"

    with subtest("two different sandboxes do not share a grant"):
        start_agent()
        machine.succeed("runuser -u alice -- ${reqSandbox} 1")
        machine.succeed("runuser -u alice -- ${reqSandbox} 1")
        n = prompts()
        assert n == 2, f"distinct sandboxes must each prompt, got {n}"
  '';
}
