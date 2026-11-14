/*
  "Hermes One" on Dave's desktops (./default.nix): the third-party Hermes
  desktop app (../../../pkgs/hermes-one, fathah/hermes-desktop), to try
  next to the official "Hermes Desktop". It reaches exactly the agents the
  official app does, the same way:

    - one "Hermes One" entry in Dave's session, its connections the
      agents of the shared app (./shared-app.nix: apps in ./apps.nix
      without `isolated`), first window on dave-hermes;
    - "Hermes One (<label>)" for each isolated app (voice, infra-space):
      a second app in that app's container (./isolated-apps.nix), with
      only that dashboard.

  Every connection is the agent's always-on dashboard,
  https://<account>.davhau.fyi, signed in with pocket-id: the app runs the
  dashboard's native sign-in in Dave's browser (in a container through
  space-gui's URL broker and loopback forward, as the official app does)
  and keeps the session cookies in its own userData. No API server, no
  API key, no ssh: nothing new is exposed on any instance. Connection
  mechanics and state paths: ./hermes-one-app.nix.

  The connections are merged in on every launch; connections Dave adds in
  the app's Settings survive. Updates come from Nix only (the build has
  the updater, the local installer and the Office setup patched out).

  Trust: in Dave's session this third-party app runs as Dave, unconfined,
  like the official shared app; a deliberate trial. In a container it
  runs as the official app's user and could read that app's cookies in
  ~/.config/Hermes: the same single dashboard, so nothing new. Left
  outbound without a click: Chromium's spell-check dictionary download
  (redirector.gvt1.com) on first start.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  desktop = config.services.hyperhermes.desktop;
  package = config.hyper.daveDesktop.hermesOne.package;
  app = import ./hermes-one-app.nix { inherit lib pkgs package; } {
    appId = "hermes-one";
    inherit (desktop) primary;
    remotes = lib.mapAttrs (agent: label: {
      inherit label;
      url = "https://${agent}.${desktop.domain}";
    }) desktop.agents;
  };
  bin = pkgs.writeShellScriptBin "hermes-one" ''exec ${app} "$@"'';
  item = pkgs.makeDesktopItem {
    name = "hermes-one";
    desktopName = "Hermes One";
    comment = "Hermes One, third-party Hermes app (${desktop.hostLabel}'s agents)";
    exec = "${bin}/bin/hermes-one";
    icon = "${package}/share/icons/hicolor/512x512/apps/hermes-one.png";
    categories = [
      "Network"
      "Chat"
    ];
  };
in
{
  options.hyper.daveDesktop.hermesOne.package = lib.mkOption {
    type = lib.types.package;
    default = pkgs.callPackage ../../../pkgs/hermes-one { };
    defaultText = lib.literalExpression "pkgs.callPackage pkgs/hermes-one { }";
    description = "The Hermes One build the \"Hermes One\" entries run.";
  };

  config.environment.systemPackages = [
    bin
    item
  ];
}
