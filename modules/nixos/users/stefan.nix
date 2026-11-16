{config, ...}: {
  users.users = {
    stefan = {
      isNormalUser = true;
      hashedPassword = "$6$lpdN2hE618bKcPTa$iwUiZEddqZaf4PqllsPplDdz8mRDMM8IYz.42cpyfJKxK66OGlRPVnyBrFYthJovj6s3TbtajjBPDAjy3kI.H.";
      # Keys in ./stefan-keys.nix (shared with som's stefan-pq slot).
      openssh.authorizedKeys.keys = import ./stefan-keys.nix;
    };
  };
}
