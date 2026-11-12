# Clan vars shared between som (./default.nix, the router) and its peers:
#   voice-gateway-ha  the bearer secret Home Assistant's hermes_conversation
#                     integration (cm-pi, ./cm-pi.nix) sends to the router.
#   voice-ntfy        ntfy on edi (./edi.nix): the router's publisher token,
#                     Dave's subscriber token and password, and the server's
#                     environment file with the declarative users, tokens
#                     and ACL (bcrypt hashes, deny-all otherwise).
# Imported by every machine that reads one of them; each machine sets the
# owners of the files it reads. Generated on the deploying host (x86),
# hence buildPackages (cm-pi is cross-built).
{ pkgs, ... }:
let
  bp = pkgs.buildPackages;
in
{
  clan.core.vars.generators.voice-gateway-ha = {
    share = true;
    files.secret = { };
    runtimeInputs = [ bp.openssl bp.coreutils ];
    script = ''
      openssl rand -hex 32 | tr -d '\n' > "$out"/secret
    '';
  };

  clan.core.vars.generators.voice-ntfy = {
    share = true;
    files.publisher-token = { };
    files.dave-token = { };
    files.dave-password = { };
    files.env = { };
    runtimeInputs = [ (bp.python3.withPackages (ps: [ ps.bcrypt ])) ];
    script = ''
      python3 - "$out" <<'PY'
      import bcrypt, secrets, string, sys
      out = sys.argv[1]
      alnum = string.ascii_lowercase + string.digits
      def token():
          return "tk_" + "".join(secrets.choice(alnum) for _ in range(29))
      def write(name, value):
          open(f"{out}/{name}", "w").write(value)
      pub, dave = token(), token()
      pw = secrets.token_urlsafe(18)
      h = lambda p: bcrypt.hashpw(p.encode(), bcrypt.gensalt(10)).decode()
      write("publisher-token", pub)
      write("dave-token", dave)
      write("dave-password", pw)
      write("env", "\n".join([
          f"NTFY_AUTH_USERS='dave:{h(pw)}:user,voicegw:{h(secrets.token_urlsafe(24))}:user'",
          f"NTFY_AUTH_TOKENS='dave:{dave}:phone,voicegw:{pub}:voice-gateway'",
          "NTFY_AUTH_ACCESS='dave:voice-unlock:ro,voicegw:voice-unlock:wo'",
      ]) + "\n")
      PY
    '';
  };
}
