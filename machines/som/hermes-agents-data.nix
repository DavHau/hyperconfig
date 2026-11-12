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
#
# `wallet = false` / `rea = false` leave those off on som (default on).
#
# `vault = false` keeps an agent out of `vault-ro` on som and vit. That
# alone does not lock it out: /vault/parquet is world-readable on bam, so
# such an agent's uid also carries a deny ACL on bam's /vault
# (../../modules/nixos/vault-ids.nix).
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
  daniel.uid = 1117;
  thaigersprint = {
    uid = 1114;
    vault = false;
  };
  # The Voice PE's untrusted voice agent (../../modules/nixos/voice-gateway):
  # vault-ro and a GPU account on vit, no wallet or REA.
  voice = {
    uid = 1119;
    wallet = false;
    rea = false;
  };
  # Daniel's second agent: GPU account on vit only, no vault, wallet or REA.
  daniel-meli = {
    uid = 1118;
    vault = false;
    wallet = false;
    rea = false;
  };
}
