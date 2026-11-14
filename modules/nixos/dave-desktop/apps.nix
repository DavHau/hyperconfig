# THE list of Hermes apps on Dave's desktops (./default.nix): dashboard
# account -> { label; isolated? }. Each one's dashboard is
# https://<account>.davhau.fyi (som's agents:
# ../../../machines/som/hermes-dashboards.nix; infra-space:
# ../infra-space/dashboard.nix). Read by ./shared-app.nix,
# ./isolated-apps.nix and machines/som/hermes-agents.nix (assertion: each
# agent in the shared app needs ssh keys, its TUI entry logs in as the
# agent).
#
#   label     shown in the app and the launcher entries.
#   isolated  unset: the agent is a connection of the shared "Hermes
#             Desktop" app and has a "Hermes TUI (<label>)" entry
#             (./shared-app.nix).
#             set: neither; it has an app of its own, "Hermes (<label>)",
#             run in a container of its own on every desktop
#             (./isolated-apps.nix). Its fields:
#               index  the container's veth subnet, 10.235.1.<4i>/30 and
#                      fd23:5ace:1:<i>::/64, 0..15 (home-networks/sites.nix
#                      claims 10.235.1.0/26); never reused.
#               uid    the container user's uid (owns its home on the
#                      host), distinct; id ladder in ../vault-ids.nix.
#               name   optional, the container's name, default
#                      hermes-<account>; at most 12 characters.
{
  dave-hermes.label = "dave-hermes";
  joe.label = "joe";
  thaigersprint.label = "thaigersprint";
  # The Voice PE's untrusted agent (../../../machines/som/hermes-agents.nix).
  voice = {
    label = "voice";
    isolated = {
      index = 0;
      uid = 1214;
    };
  };
  # The fleet admin's agent in som's infra-space container
  # (../infra-space/hermes.nix). Its app only talks https to the
  # dashboard, so it needs no infra-space container on the desktop.
  infra-space = {
    label = "infra-space";
    isolated = {
      index = 1;
      uid = 1215;
      name = "hermes-infra";
    };
  };
}
