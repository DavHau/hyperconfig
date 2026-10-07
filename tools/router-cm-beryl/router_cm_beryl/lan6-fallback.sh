#!/bin/sh
# lan6-fallback: keep the LAN on its public /64 while no uplink carries IPv6.
#
# Normally IPv6 is relayed from the AIS uplink (dhcp.lan.{ra,dhcpv6,ndp}=relay,
# see PROTOCOL.md). The backup uplinks (iPhone tethering, repeater) deliver no
# IPv6, so the relay has nothing to pass on and every LAN host loses its
# 2405:... address. While that is the case this script makes the router
# announce the last prefix seen on wan6 itself (ra=server, no default route):
# hosts keep their token addresses and reach each other on them; nothing is
# routed off the LAN. As soon as an uplink has a global /64 again, relay mode
# returns.
#
# Installed as /usr/sbin/lan6-fallback; /etc/hotplug.d/iface/99-lan6-fallback
# runs it on uplink ifup/ifdown/ifupdate. Mode marker: network.lan.ip6prefix
# is set only while in fallback. Last good prefix: /etc/lan6-fallback.prefix.

STATE=/etc/lan6-fallback.prefix

log() { logger -t lan6-fallback "$*"; }

# Print "<iface> <prefix/64>" for the first uplink that is up with a global /64.
uplink_prefix() {
	for i in wan6 wwan6 tethering6; do
		st=$(ifstatus "$i" 2>/dev/null) || continue
		[ "$(echo "$st" | jsonfilter -e '@.up')" = true ] || continue
		dev=$(echo "$st" | jsonfilter -e '@.l3_device')
		[ -n "$dev" ] || continue
		p=$(ip -6 route show dev "$dev" | awk '$1 ~ /^[23][0-9a-f]*:[0-9a-f:]*\/64$/ { print $1; exit }')
		[ -n "$p" ] && { echo "$i $p"; return 0; }
	done
	return 1
}

apply() {
	uci commit network
	uci commit dhcp
	/etc/init.d/network reload
	/etc/init.d/odhcpd restart
}

lock /var/lock/lan6-fallback
trap 'lock -u /var/lock/lan6-fallback' EXIT

current=$(uci -q get network.lan.ip6prefix)

if up=$(uplink_prefix); then
	iface=${up% *}
	prefix=${up#* }
	if [ "$iface" = wan6 ] && [ "$(cat "$STATE" 2>/dev/null)" != "$prefix" ]; then
		echo "$prefix" > "$STATE"
		log "recorded wan6 prefix $prefix"
	fi
	[ -n "$current" ] || exit 0
	log "$iface carries $prefix: back to relay mode"
	uci -q delete network.lan.ip6prefix
	uci set dhcp.lan.ra=relay
	uci set dhcp.lan.dhcpv6=relay
	uci set dhcp.lan.ndp=relay
	uci -q delete dhcp.lan.ra_flags
	apply
else
	prefix=$(cat "$STATE" 2>/dev/null)
	if [ -z "$prefix" ]; then
		log "no IPv6 uplink and no recorded prefix: nothing to announce"
		exit 0
	fi
	[ "$current" = "$prefix" ] && exit 0
	log "no IPv6 uplink: announcing $prefix on lan"
	uci set network.lan.ip6prefix="$prefix"
	uci set dhcp.lan.ra=server
	uci set dhcp.lan.dhcpv6=disabled
	uci set dhcp.lan.ndp=disabled
	uci set dhcp.lan.ra_flags=none
	apply
fi
