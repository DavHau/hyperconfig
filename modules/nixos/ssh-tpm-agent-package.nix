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
})
