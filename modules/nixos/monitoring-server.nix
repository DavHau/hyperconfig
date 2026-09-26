# Local overrides for the clan-core monitoring server (Mimir + Loki).
#
# Retention: the upstream service keeps everything forever; the monitoring
# server has a small disk.
#
# Ring addresses: upstream pins only some rings to 127.0.0.1 and lets the
# rest look up an address on `networking.interfaces`, which can name a NIC
# the running kernel does not have (edi: facter says enp1s0, the NIC is eth0)
# - Mimir and Loki then refuse to start. Both run single-node on loopback, so
# give every ring an explicit address; interface lookup is then skipped.
# (dskit rejects loopback interfaces, so instance_interface_names = [ "lo" ]
# does not work.)
{ config, ... }:
let
  retention = "30d";
  addr = "127.0.0.1";
in
{
  services.mimir.configuration = {
    limits.compactor_blocks_retention_period = retention;

    memberlist.advertise_addr = addr;
    alertmanager.sharding_ring.instance_addr = addr;
    compactor.sharding_ring.instance_addr = addr;
    frontend.address = addr;
    query_scheduler.ring.instance_addr = addr;
    ruler.ring.instance_addr = addr;
    store_gateway.sharding_ring.instance_addr = addr;
  };

  services.loki.configuration = {
    common.instance_addr = addr;
    memberlist.advertise_addr = addr;
    limits_config.retention_period = retention;
    compactor = {
      working_directory = "${config.services.loki.dataDir}/compactor";
      retention_enabled = true;
      delete_request_store = "filesystem";
    };
  };
}
