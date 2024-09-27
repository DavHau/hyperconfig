{config, ...}: {
  users.users = {
    stefan = {
      isNormalUser = true;
      hashedPassword = "$6$lpdN2hE618bKcPTa$iwUiZEddqZaf4PqllsPplDdz8mRDMM8IYz.42cpyfJKxK66OGlRPVnyBrFYthJovj6s3TbtajjBPDAjy3kI.H.";
      openssh.authorizedKeys.keys =
        [
          # "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA5PxR4yPCXBhL15II41hBF8V0d9D4ZRmICa3u09nNe8 hauer@MatebookX"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO/PPzetdVPjZhFumovpMO8Wc3BP05bBEbrg+C0iMhDo stefan-thinkpad"
        ];
    };
  };
}
