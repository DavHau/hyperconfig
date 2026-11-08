# Admin password of the ISP router at playa (http://192.168.10.1, user
# `admin`): the LAN's gateway and DHCP server. Read by the playa ISP router
# tooling via
#     clan vars get amy router-playa-isp/password
# so it never lands on a machine's disk: deploy = false.
#
# Shared: one router, one password, entered once:
#     clan vars generate amy --generator router-playa-isp
{
  clan.core.vars.generators.router-playa-isp = {
    share = true;
    # A persisted prompt IS the file: the var holds exactly the password.
    prompts.password = {
      type = "hidden";
      persist = true;
      description = "admin password of the ISP router at playa (http://192.168.10.1, user admin)";
    };
    files.password.deploy = false;
  };
}
