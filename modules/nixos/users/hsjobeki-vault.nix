# hsjobeki on som: SSH login with read-only access to the vault datasets
# mounted at /vault (vault-nfs-client.nix).
#
# Same footing as momentum (../vault-ids.nix): NOT in the `vault` group, which
# is read+write on the datasets. What is readable then is exactly what the
# modes hand to "other" - /vault/parquet/momentum (2775, files 664); the
# group-only trees (depth, photos, media, misc: 2770) stay closed. The account
# owns nothing on bam, so the UID only needs to be unique per client; pinned
# anyway so the principal is stable if it ever lands on another wg-vault
# client (1100/1101 are momentum/vault, see ../vault-ids.nix).
{
  users.users.hsjobeki = {
    isNormalUser = true;
    uid = 1102;
    description = "hsjobeki - read-only vault consumer";
    openssh.authorizedKeys.keys = [
      # github.com/hsjobeki.keys (fetched 2026-09-15)
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGLuev3+8kF+pd1YnCRR7Kw9i9DswOMvGhvdQq6dEIJF hsjobeki"
    ];
  };
}
