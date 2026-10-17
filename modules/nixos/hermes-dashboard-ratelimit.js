// The sign-in rate limit's client key (./hermes-dashboard-public.nix): the
// IPv4 address, or the /64 of an IPv6 address. One subscriber usually holds
// a whole /64, so keying on the full address would hand it 2^64 budgets.
// A failure falls back to the full address: an empty key would put every
// client into one bucket, and one client could then block everyone's sign-in.
function clientNet(r) {
  try {
    var addr = r.rawVariables.binary_remote_addr;
    if (addr.length === 16) {
      return addr.slice(0, 8).toString("hex") + "/64";
    }
  } catch (e) {
    // fall through to the full address
  }
  return r.remoteAddress;
}

export default { clientNet };
