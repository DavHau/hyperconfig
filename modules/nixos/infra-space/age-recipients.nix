# The clan vars' age recipients (vars.settings.recipients.default in
# ../../flake-parts/nixosConfigurations.nix): infra-space member -> the
# recipient of its TPM age identity. Each was made as infra in that
# member's container with `age-plugin-tpm --generate` (./default.nix,
# Identities), so the key is sealed to the member's TPM and decrypts only
# there. A new or replaced member: add its recipient here, then
# `clan vars fix` (re-encrypts every machine's age key, through which the
# secrets are encrypted, to the new set).
{
  som = "age1tag1q0rtkh6z46j4z8hujk0yt663p568mh8vz6pd69e08zxjhkp4zdld6p3ny5l";
  amy = "age1tag1qfapu7pkadj2qyda3zcfj39c9sa68m6gt8tj7d3x4ctcwt4vlzpjwjf8dnj";
}
