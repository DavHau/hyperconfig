# The fixed identity of `web-bench launch --egress mullvad`
# (tools/web-bench): uid rules (./mullvad-egress) need a uid known at build
# time, which a DynamicUser does not have. No home, no shell; only the bench
# runs as it.
{
  users.users.web-bench-mullvad = {
    isSystemUser = true;
    uid = 1210;
    group = "web-bench-mullvad";
  };
  users.groups.web-bench-mullvad.gid = 1210;
}
