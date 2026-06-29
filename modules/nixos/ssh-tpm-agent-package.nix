# ssh-tpm-agent, patched to gate every signature behind a confirmation scoped to
# (uid, login-session, sandbox, requesting binary): see
# ssh-tpm-agent-confirm.patch. A grant is cached per (session, sandbox, binary)
# so repeated use from the same terminal/sandbox is silent until it expires; a
# different binary, session, or sandbox (pid namespace) re-prompts. No new Go
# dependencies, so the upstream vendorHash is unchanged.
#
# Factored out of ssh-tpm-agent.nix so the NixOS module and the
# ssh-tpm-confirm-cache VM test build the exact same derivation.
{ pkgs }:
pkgs.ssh-tpm-agent.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./ssh-tpm-agent-confirm.patch ];
})
