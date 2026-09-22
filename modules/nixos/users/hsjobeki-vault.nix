# hsjobeki on som: SSH login with read-only access to /vault/parquet
# mounted at /vault (vault-nfs-client.nix) via the `vault-ro` group
# (../vault-ids.nix). The account owns nothing on bam, so the UID only needs
# to be unique per client; pinned anyway so the principal is stable if it
# ever lands on another wg-vault client (id ladder in ../vault-ids.nix).
{
  users.users.hsjobeki = {
    isNormalUser = true;
    uid = 1102;
    description = "hsjobeki - read-only vault consumer";
    extraGroups = [ "vault-ro" ];
    openssh.authorizedKeys.keys = [
      # github.com/hsjobeki.keys (fetched 2026-09-15)
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGLuev3+8kF+pd1YnCRR7Kw9i9DswOMvGhvdQq6dEIJF hsjobeki"
    ];
  };
}
