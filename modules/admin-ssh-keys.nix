# Dave's own ssh keys. Root on every machine (the clan `sshd` instance,
# modules/flake-parts/nixosConfigurations.nix), the `infra` user in the
# infra-space containers (modules/nixos/infra-space), the site routers
# (modules/flake-parts/apps.site-routers-apply.nix) and Roman's Home
# Assistant SSH add-ons (home-assistant/hosts.nix) all take them from
# here, never from root's merged key list.
{
  "dave-tpm" = "ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBMAWEy2KMRae6D0kreSie2gA7s3g8x3QVNtdotxY4MDVO2dim6kc1OlGovByt06XGa/H1kMwIlc+RhfuJ/eRioGhrJ13SrDeJegC0T1iyIIZY67WMNSj5vZ0bJOmIQvm1A== grmpf@amy";
  "dave" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDuhpzDHBPvn8nv8RH1MRomDOaXyP4GziQm7r3MZ1Syk";
  "phone" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJwzL0rt4J+kzggV4pFXf9yh9zBF6n4hdXXVbCB7p1x6";
}
