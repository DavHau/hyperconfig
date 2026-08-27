# ssh-tpm-agent, patched to gate every signature behind a confirmation: see
# ssh-tpm-agent-confirm.patch. The dialog lists the requesting process and its
# ancestors; the user grants trust to ONE of them (e.g. the sandbox root) and
# the grant covers that process and all of its descendants until it expires,
# the process dies, or the agent restarts. Grants are keyed by (pid, start
# time), read from world-readable /proc/<pid>/stat, so they work for sandboxed
# peers too. No new Go dependencies, so the upstream vendorHash is unchanged.
#
# Factored out of ssh-tpm-agent.nix so the NixOS module and the
# ssh-tpm-confirm-cache VM test build the exact same derivation.
{ pkgs }:
pkgs.ssh-tpm-agent.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./ssh-tpm-agent-confirm.patch ];

  # nixpkgs' preCheck rewrites ENOKEY -> ENOENT in the internal/keyring tests
  # (NixOS/nixpkgs#394097), i.e. it asserts the errno some builders return
  # instead of the one request_key(2) actually returns. On our kernels the
  # syscall returns ENOKEY, so the rewritten assertions fail and checkPhase
  # breaks the build. Keep only the part that is genuinely broken upstream
  # (cmd/scripts_test.go, a testscript suite that needs a real TPM).
  preCheck = ''
    rm -f cmd/scripts_test.go
  '';
})
