# The clan vars generator binding nas' ZFS passphrase to the tang server on
# the ESPHome plug at casa (locations/casa/esphome, rolladen-gz). The
# advertisement is pinned from the shared var esphome-casa/tang_adv (public,
# in the repo), so generating needs no network and no prompt, and trusts
# exactly the signing key whose thumbprint is esphome-casa/tang_thp; the
# server itself only takes part when the JWE is decrypted.
#
# A function so the flake checks (./test.nix) can bind against a tang of
# their own:
#   advFile     the advertisement (JWS JSON), a path
#   thp         signing key thumbprint clevis checks the adv against, or null
#   validation  changes of it make clan regenerate the binding
{
  pkgs,
  url,
  advFile,
  thp ? null,
  validation ? null,
}:
let
  # clevis reads a string `adv` as a file name.
  cfg = builtins.toJSON (
    {
      inherit url;
      adv = "${advFile}";
    }
    // pkgs.lib.optionalAttrs (thp != null) { inherit thp; }
  );
in
{
  dependencies = [ "zfs-passphrase" ];
  files.jwe = { }; # secret, deployed (root:root 0400)
  runtimeInputs = [
    pkgs.clevis
    pkgs.coreutils
    pkgs.jose
    pkgs.jq
  ];
  inherit validation;
  script = ''
    # clevis checks that the pinned thp signed the advertisement (no prompt
    # then) and fails otherwise. The passphrase file has no newline.
    clevis encrypt tang ${pkgs.lib.escapeShellArg cfg} < "$in/zfs-passphrase/passphrase" > "$out/jwe"
    # The protected header must name the pinned server.
    hdr=$(cut -d. -f1 "$out/jwe" | jose b64 dec -i- | jq -r '.clevis.tang.url')
    [ "$hdr" = ${pkgs.lib.escapeShellArg url} ]
  '';
}
