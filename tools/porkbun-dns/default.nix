{ writeShellApplication, curl, jq }:
writeShellApplication {
  name = "porkbun-dns";
  # clan comes from the devshell (it is not a nixpkgs package).
  runtimeInputs = [ curl jq ];
  text = builtins.readFile ./porkbun-dns.sh;
}
