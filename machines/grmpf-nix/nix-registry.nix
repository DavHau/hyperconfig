{pkgs, ...}: {
  nix.registry = {
    n.to = {
      type = "path";
      path = pkgs.path;
    };
  };
}
