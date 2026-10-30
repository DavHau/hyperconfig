# Git LFS for every user of the host: git-lfs on PATH with its filters in
# /etc/gitconfig (no per-user `git lfs install`), and git-lfs-transfer, so
# clients clone and push LFS objects of repositories here over plain SSH
# (git-lfs' pure SSH transfer protocol) without an LFS HTTP server.
# git-lfs-transfer runs as the SSH user, with that user's file permissions,
# like git-upload-pack and git-receive-pack.
{
  programs.git = {
    enable = true;
    lfs = {
      enable = true;
      enablePureSSHTransfer = true;
    };
  };
}
