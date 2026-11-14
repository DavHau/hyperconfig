# Password of the iodine IP-over-DNS tunnel (ns.bruch-bu.de). Shared: server
# (./role-iodine) and clients (none left; the old iodine-client.nix is in
# git history) must hold the same value,
# entered once:
#     clan vars generate <any-host> --generator iodine-password
# iodine/iodined read it as root via stdin before dropping privileges, so the
# default root-only file is enough.
{
  clan.core.vars.generators.iodine-password = {
    share = true;
    # A persisted prompt IS the file — no generator script.
    prompts.password = {
      type = "hidden";
      persist = true;
      description = "iodine tunnel password (ns.bruch-bu.de)";
    };
  };
}
