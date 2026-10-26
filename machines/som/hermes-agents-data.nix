# som's hermes agents (./hermes-agents.nix) as plain data, because two
# evaluations need it: som runs them, and vit's GPU host
# (../../modules/nixos/hermes-agents-gpu-host.nix) gives each one an account
# with the same uid that its own key (clan var hermes-agent-ssh-<agent>)
# logs in to.
#
# The uid is the agent's identity on both hosts and its serve ports derive
# from it, so it is pinned and never reused. stefan's and momentum's are
# shared identities owned elsewhere (../../modules/nixos/users/stefan-vault.nix,
# ../../modules/nixos/vault-ids.nix, whose id ladder lists them all); the
# values here must match.
{
  stefan.uid = 1002;
  egg.uid = 1004;
  dave-hermes.uid = 1005;
  momentum.uid = 1100;
  pinpox.uid = 1104;
  adam.uid = 1105;
  j.uid = 1106;
  willi.uid = 1108;
  domi.uid = 1109;
  rti.uid = 1110;
  chris.uid = 1111;
  b3x.uid = 1112;
  joe.uid = 1113;
}
