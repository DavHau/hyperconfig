# Keep wired interfaces usable on a peer-to-peer cable (laptop <-> laptop).
#
# Stock NetworkManager treats a link with no DHCP server and no router
# advertisement as a failed connection: DHCPv4 times out, SLAAC never sees an
# RA, both address families fail, and after `connection.autoconnect-retries`
# NM tears the device down and *flushes the IPv6 link-local it owns*. Since
# NM >= 1.40 it sets `net.ipv6.conf.<if>.addr_gen_mode = 1` (none) and manages
# `fe80::` itself, so the kernel does not regenerate one: the interface ends up
# UP, with carrier, and no address at all. Observed on both amy and vit.
#
# There is no global NetworkManager.conf knob for this - `ipv6.method` is not
# among the properties a `[connection*]` default section may set - so the fix
# is two profiles ranked by autoconnect-priority. NM tries `wired-auto` first
# and, once it gives up, falls through to `wired-ll`, which declares success
# with only a link-local address. That activation *succeeds*, so nothing is
# ever flushed.
#
# Measured on vit: wired-auto fails after ~9s (the two timeouts below run in
# parallel), wired-ll is up ~1.5s later. On a real network wired-auto simply
# succeeds and the fallback is never reached, so there is no added latency.
#
# Caveat: a carrier blip shorter than NM's 60s deferral does not re-run profile
# selection, so bare-cable -> real-network without a true unplug stays on
# wired-ll. Unplugging a USB dongle destroys the netdev, which does re-run it.
{ ... }:
{
  networking.networkmanager.ensureProfiles.profiles = {
    # Preferred: behave exactly like a normal wired connection.
    wired-auto = {
      connection = {
        id = "wired-auto";
        uuid = "0c4f7a19-a433-4690-b01c-819de1ea3ddf";
        type = "ethernet";
        # No interface-name: match every wired NIC. The USB dongles rename
        # themselves per port (enp195s0f4u1 on amy, enp0s20f0u5u1 on vit), so
        # pinning a name would silently stop matching.
        autoconnect = true;
        autoconnect-priority = 10;
        # Stock is 4 tries; each costs the full timeouts below before the
        # fallback gets a turn.
        autoconnect-retries = 1;
      };
      ipv4 = {
        method = "auto";
        dhcp-timeout = 8; # stock 45
      };
      ipv6 = {
        method = "auto";
        ra-timeout = 8; # stock 30
        # addr-gen-mode deliberately left at NM's default (stable-privacy):
        # on a foreign network an EUI-64 identifier would put this machine's
        # MAC into its globally routable address.
      };
    };

    # Fallback: bare cable. Link-local only, and therefore always successful.
    wired-ll = {
      connection = {
        id = "wired-ll";
        uuid = "5c0d1644-287d-440c-930f-e18fc7bee412";
        type = "ethernet";
        autoconnect = true;
        autoconnect-priority = 0;
        autoconnect-retries = 1;
      };
      # IPv4 off rather than link-local: a 169.254/16 address is picked at
      # random per activation, which defeats the point of a reproducible name.
      ipv4.method = "disabled";
      ipv6 = {
        method = "link-local";
        # Derive fe80:: from the MAC (RFC 4291 modified EUI-64) so the address
        # is reproducible across reboots, reinstalls and machines, and can be
        # computed by hand from `ip link`. ethernet.cloned-mac-address is
        # already "preserve" in NetworkManager.conf, so the MAC is not
        # randomised out from under this.
        addr-gen-mode = "eui64";
      };
    };
  };
}
