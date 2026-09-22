{
  perSystem = { pkgs, ... }: {
    packages.porkbun-dns = pkgs.callPackage ../../tools/porkbun-dns { };
  };
}
