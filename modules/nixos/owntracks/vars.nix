# The shared generator of ./default.nix, for cm-pi (HA reads webhook-id
# and encryption-key) and edi (owntracks-phone derives its files from
# them); som does not import it. Generated on the deploying host (x86),
# hence buildPackages (cm-pi is cross-built).
{ pkgs, ... }:
let
  bp = pkgs.buildPackages;
in
{
  imports = [ ./default.nix ];

  clan.core.vars.generators.owntracks-secrets = {
    share = true;
    files.webhook-id = { };
    # 32 hex chars = 32 bytes, libsodium secretbox's key length (OwnTracks
    # and HA both cut/pad the UTF-8 string to 32 bytes).
    files.encryption-key = { };
    runtimeInputs = [
      bp.openssl
      bp.coreutils
    ];
    script = ''
      openssl rand -hex 32 | tr -d '\n' > "$out"/webhook-id
      openssl rand -hex 16 | tr -d '\n' > "$out"/encryption-key
    '';
  };
}
