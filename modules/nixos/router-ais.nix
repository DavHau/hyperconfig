# Admin credentials of the AIS-issued ZTE F6107A router (http://192.168.1.1),
# the IPv6 firewall in front of the whole home LAN. Consumed by the repo's
# `router-ais` CLI (tools/router-ais), which reads the value via
#     clan vars get <machine> router-ais/password
# so the secret never lands on a machine's disk: deploy = false. The
# username is the router's fixed `admin`; only the password is state.
#
# Shared: one router, one password, entered once:
#     clan vars generate <any-host> --generator router-ais
{
  clan.core.vars.generators.router-ais = {
    share = true;
    # A persisted prompt IS the file — no generator script, so the var holds
    # exactly the password and nothing else.
    prompts.password = {
      type = "hidden";
      persist = true;
      description = "admin password of the AIS ZTE router at 192.168.1.1";
    };
    files.password.deploy = false;
  };
}
