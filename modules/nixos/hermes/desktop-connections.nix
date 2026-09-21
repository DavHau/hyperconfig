# Extra gateways for grmpf's hermes-desktop on amy, declared here so the
# app needs no manual setup. The spaces launcher (hermes/cli.nix,
# services.hermes-microvm.desktop.connections) renders the app's
# connections.json on every launch: this machine's own agent stays the
# window's primary; the entries below appear as `nix-<name>` in the
# Connections registry and snap back if edited in the app. Entries the
# user adds in the app survive.
#
# som's agents run native in their own accounts and their web dashboards
# sit behind hermes' password gate (../hermes-dashboard-public.nix, bound
# 0.0.0.0), which rejects the app's static-token auth. So the desktop
# reaches them the way it can authenticate declaratively: the SSH
# connection kind. The app runs `hermes serve --isolated` over ssh as that
# account, tunnels the ephemeral port and adopts the token the remote
# mints. On som the command lands in spaces' host `hermes` shim, whose
# native arm exports the account's real HERMES_HOME, so it serves the
# same state (sessions, memories) the gateway and dashboard use. Auth is
# grmpf's admin key, which the clan admin role puts on those accounts
# (../dave-hermes.nix). One `hermes serve` process per open connection,
# alive while the app is connected.
{ ... }:
{
  services.hermes-microvm.desktop.connections.remotes.som-dave-hermes = {
    kind = "ssh";
    label = "dave-hermes on som";
    host = "som.d";
    user = "dave-hermes";
  };
}
