/*
  Dave's desktop apps, the same set on every desktop that imports
  ../dave.nix (amy, vit, som):

    - ./shared-app.nix: the shared "Hermes Desktop" app (hyperhermes'
      desktop module) for som's trusted agents;
    - ./isolated-apps.nix: "Hermes (voice)" and "Hermes (infra-space)",
      each the hermes app in a confined container of its own here
      (../space-gui on the desktop user's session);
    - ./hermes-one.nix: "Hermes One" and "Hermes One (<isolated label>)",
      the third-party Hermes One app on the same agents, the same way;
    - the shells: "<space> (<machine>)" plus a herdr machine of the same
      label for every copy of infra-space and of the named spaces
      (../spaces/client.nix).
    - ./mesh-dashboards.nix: the apps' dashboard and sign-in names resolve
      to som's and edi's yggdrasil addresses (not on som).

  Which agent gets which kind of app: ./apps.nix.

  `hyper.daveDesktop.user` is the desktop user whose session shows the
  container apps (space-gui's host user) and whose herdr gets the spaces:
  grmpf on amy, dave elsewhere.
*/
{ config, lib, ... }:
let
  cfg = config.hyper.daveDesktop;
in
{
  imports = [
    ./shared-app.nix
    ./isolated-apps.nix
    ./hermes-one.nix
    ./mesh-dashboards.nix
    ../spaces/client.nix
    ../voxtype-archive.nix
  ];

  options.hyper.daveDesktop.user = lib.mkOption {
    type = lib.types.str;
    default = "dave";
    example = "grmpf";
    description = "Dave's desktop user here: the session the container apps show on, and the herdr that gets the spaces.";
  };

  config = {
    hyper.spaceGui.hostUser = cfg.user;
    hyper.spacesClient.herdrUser = cfg.user;
    # Every dictation take kept for replay (../voxtype-archive.nix).
    hyper.voxtypeArchive.enable = lib.mkDefault true;
    # Whisper initial prompt for Dave's dictation (spaces-os voxtype.nix;
    # VAD and the rest stay at its defaults). Measured against the spaces-os
    # default on 20 real takes + TTS glossary sentences with the production
    # small model: term accuracy 21% -> 56%, jargon WER en 16.7 -> 5.8,
    # de 31.1 -> 19.4, no glossary insertions into control sentences or
    # real takes, same latency; only regression one German control word.
    # Evaluation: /var/lib/hermes/infra/home/cache/scratch/stt-eval/ (prompt C).
    spaces.voxtype.initialPrompt = "Dave dictates to his Claude Codes about hyperconfig, his NixOS fleet. Glossary: Grafana, Mimir, SearXNG, Nextcloud, pocket-id, OIDC, Mullvad, Tailscale, WireGuard, ZeroTier, Yggdrasil, nftables, tang, Clevis, LUKS, ZFS, nspawn, sudo, systemd, nixpkgs, flake.lock, Home Assistant, ESPHome, Wyoming, Whisper, voxtype, OpenRouter, TeamClaude, Claude, afk, omp, Ghostty, Noctalia, niri, jj, clan vars, hyperhermes, infra-space, dave-hermes. Machines: amy, vit, som, bam, edi, sgp, nas, joy, cm-pi.";
  };
}
