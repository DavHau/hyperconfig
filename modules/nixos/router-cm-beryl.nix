# Admin credentials of the GL.iNet Beryl (cm-beryl, OpenWrt) at http://192.168.8.1 —
# the LAN's IPv6 relay and the second firewall between the AIS ZTE and the
# hosts. Consumed by the repo's `router-cm-beryl` CLI (tools/router-cm-beryl),
# which reads the value via
#     clan vars get <machine> router-cm-beryl/password
# so the secret never lands on a machine's disk: deploy = false. The user is
# the fixed `root` (ssh and web UI share the admin password on GL.iNet).
#
# Shared: one router, one password, entered once:
#     clan vars generate <any-host> --generator router-cm-beryl
{
  clan.core.vars.generators.router-cm-beryl = {
    share = true;
    # A persisted prompt IS the file — no generator script, so the var holds
    # exactly the password and nothing else.
    prompts.password = {
      type = "hidden";
      persist = true;
      description = "admin/root password of the GL.iNet router at 192.168.8.1";
    };
    files.password.deploy = false;
  };
}
