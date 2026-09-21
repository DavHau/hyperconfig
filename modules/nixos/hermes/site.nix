# Hermes Agent (NousResearch), one microvm per user — the machinery lives
# in the spaces flake (nixosModules.hermes); the shared site wiring (p0
# provider, secrets, restart hooks) in ../hermes-common.nix. This file
# keeps only amy's own choices: the vit.d model seed, simplex/gpu, and
# grmpf's agent.
#
# Entry points (as grmpf): `hermes` (CLI/TUI via ssh into the VM) and
# `hermes-desktop` (Electron app on the VM's backend); GUI/TUI also ship
# .desktop entries for app launchers.
{ config, lib, pkgs, inputs, ... }:
{
  imports = [
    inputs.spaces.nixosModules.hermes
    ../hermes-common.nix
    ./desktop-connections.nix
  ];

  # The module derives ports/CID/MAC from the uid and asserts it matches
  # users.users.grmpf.uid — declare it (userborn allocated 1000 for the
  # first normal user).
  users.users.grmpf.uid = 1000;

  # grmpf's agent: openrouter + telegram (the pre-common `telegram` var
  # name is kept so vars/per-machine/amy/telegram/ stays valid) + p0.
  hyper.hermes.users.grmpf.telegram = {
    enable = true;
    generator = "telegram";
  };

  # Shared key: same var pi-chat uses.
  spaces.openrouter = {
    enable = true;
    apiKeyFile = config.clan.core.vars.generators.openrouter.files.apikey.path;
  };

  services.hermes-microvm = {
    enable = true;
    # amy has a second normal user (dave, no declared uid — the clan
    # user role) that must not get a VM; keep the pre-port behavior of
    # explicitly declared users only.
    provisionNormalUsers = false;
    # Default brain: qwen3.6 on vit's llama-swap over yggdrasil, over the
    # common p0 default. Seeded ONCE into a fresh guest config; runtime
    # /model switches persist (amy's existing guest already has a model —
    # the seed never fires). p0 stays registered as a second provider
    # (hermes-common.nix); switch with /model in the TUI once and it
    # persists.
    initialModel = {
      provider = "custom";
      base_url = "http://vit.d:8012/v1";
      default = "qwen3.6:35b-iq4_xs";
    };
    # Second control channel beside telegram. The guest runs its own
    # simplex-chat daemon; the profile address lands in
    # ~/hermes/simplex-address.txt (same path on the host). Connect to it
    # from the phone and the adapter accepts the request.
    #
    # Authorization uses the upstream pairing flow, NOT an allowlist:
    # message the agent from the phone, it replies with a one-time code,
    # and `hermes pairing approve simplex <CODE>` (run via the hermes shim,
    # which lands in the guest over vsock-ssh) approves that contactId
    # durably in the vault-backed pairing store.
    #
    # No SIMPLEX_ALLOWED_USERS on purpose. A display-name entry is an
    # authorization bypass: names are attacker-chosen profile metadata, and
    # whoever claims a listed name while no live contact holds it gets full
    # control (upstream #44729/#44730, CWE-290; the pending fix #44741
    # removes name matching entirely). A contactId entry is safe but
    # transient - ids are renumbered on every re-pair. Pairing binds the
    # actual contact that received the code, so neither problem exists.
    simplex.enable = true;
    gpu.enable = true;
  };
}
