# slot-onboard <machine> <slot>
#
# Prints the handoff for the agent (or person) adopting one container slot
# (hyperhermes' nixosModules.container-slots), written to be pasted as is: where the
# slot is, how to deploy into it, what the guest config must and need not
# contain, and which host directories it gets. Notes meant for the operator
# (router allow rules, keys that reach the bootstrap system) go to stderr,
# so stdout stays the message. Everything is read from the flake, so the
# handoff matches what is declared. Run from the repo root (or set
# HYPERCONFIG to it).

usage() {
  echo "usage: slot-onboard <machine> <slot>" >&2
  exit 2
}

[ $# -eq 2 ] || usage
machine=$1
slot=$2
repo=${HYPERCONFIG:-.}

note() { echo "slot-onboard: $*" >&2; }

# One eval for every fact, of the slot options only (not the host system).
# The slot name is spliced into the expression; \${...} is Nix's, not the
# shell's.
expr=$(cat <<EOF
c:
let
  cs = c.services.containerSlots;
  s = cs.slots."$slot" or null;
  comment = k: let p = builtins.filter builtins.isString (builtins.split " " k);
    in if builtins.length p > 2 then builtins.elemAt p 2 else "(no comment)";
in
if !cs.enable || s == null then { exists = false; } else {
  exists = true;
  inherit (s) id mode memoryMax cpuQuota;
  inherit (cs) ipv6Prefix;
  keys = map comment s.deployKeys;
  shares = builtins.attrNames s.shares;
}
EOF
)
facts=$(nix eval --json "$repo#nixosConfigurations.$machine.config" --apply "$expr" 2>/dev/null) || {
  echo "slot-onboard: cannot evaluate nixosConfigurations.$machine" >&2
  exit 1
}

if [ "$(jq -r .exists <<<"$facts")" != true ]; then
  echo "slot-onboard: no container slot '$slot' on $machine" >&2
  exit 1
fi

# Addresses as the module derives them (ipv6Of, localMacAddress, isolated v4).
id=$(jq -r .id <<<"$facts")
mode=$(jq -r .mode <<<"$facts")
ipv6="$(jq -r .ipv6Prefix <<<"$facts")::5107:$(printf '%x' "$id")"
ipv4=10.43.$id.2
mac=$(printf '02:43:51:07:00:%02x' "$id")
keys=$(jq -r '.keys | join(", ")' <<<"$facts")
memory=$(jq -r '.memoryMax // empty' <<<"$facts")
cpu=$(jq -r '.cpuQuota // empty' <<<"$facts")
mapfile -t shares < <(jq -r '.shares[]' <<<"$facts")

note "the bootstrap system lets in root with: $keys"
note "inbound from the internet needs the router allow rules (once per slot):"
note "  router-ais ipv6-rules add --address $ipv6 --name $slot"
note "  router-cm-beryl -J root@som.d ipv6-rules add --address $ipv6 --name $slot"

if [ "$mode" = lan ]; then
  addresses="eth0 carries the IPv6 address when your init starts;
  NixOS's default DHCP client takes the IPv4 lease."
else
  addresses="eth0 carries both addresses, with default routes, when
  your init starts."
fi

cat <<EOF
# Container slot "$slot" on $machine

A NixOS container that behaves like a small VM you own: you deploy whole
systems into it from your repo. $machine only provides its shell (network,
limits, shared directories) and never touches the system inside.

## Where it is

- ssh root@$ipv6
EOF
if [ "$mode" = lan ]; then
  cat <<EOF
- Mode lan: a peer on $machine's LAN, unfiltered. IPv4 comes from
  the LAN's DHCP (MAC $mac, so the lease is stable); the IPv6
  default route from the router's RAs.
EOF
else
  cat <<EOF
- Mode isolated: internet only (IPv4 $ipv4, NAT'd). The LAN, private
  ranges, other slots and $machine itself are unreachable from it.
EOF
fi
cat <<EOF
- Inbound from the internet reaches the IPv6 address once the operator
  has opened it on the routers; your own firewall decides the rest.

## Deploying

Until your first deploy the slot runs a minimal bootstrap system (sshd,
root reachable with: $keys). From your repo:

    nixos-rebuild switch --flake .#<config> \\
      --target-host root@[$ipv6] \\
      --build-host root@[$ipv6]

Builds run on $machine's nix-daemon through the slot (sandboxed, as an
untrusted user, binary caches allowed), so nothing has to be signed or
pushed. Keep the brackets: a bare IPv6 address breaks nix-copy-closure.

## What your config needs

- boot.isNspawnContainer = true;
- services.openssh.enable = true; plus your key in
  users.users.root.openssh.authorizedKeys.keys, or keep the bootstrap's
  services.openssh.authorizedKeysFiles =
  [ "/var/lib/container-slot/authorized_keys" ]; ($machine provides the
  keys above there at every start). Without either, your access is gone
  after your first deploy, and $machine does not repair a slot that
  locked its deployer out.
- To keep the slot's ssh host key (generated and kept by $machine, so it
  survives resets and redeploys and $machine can pin it):
  services.openssh.hostKeys = [ { type = "ed25519";
  path = "/var/lib/container-slot/ssh_host_ed25519_key"; } ];

What it need not (and should not) do:

- addresses: $addresses
- DNS: /etc/resolv.conf (public resolvers) is copied in at every start.
- kernel, bootloader, filesystems: the slot shares $machine's kernel and
  reads $machine's /nix/store.
EOF

if [ ${#shares[@]} -gt 0 ]; then
  echo
  echo "## Shared directories"
  echo
  for s in "${shares[@]}"; do
    echo "- $s"
  done
  cat <<EOF

They look owned by root and world-writable inside; the host account behind
each share decides what actually succeeds (chown/chgrp are ignored). A share
can be empty for a while (its source down); it fills in without a restart.
EOF
fi

if [ -n "$memory$cpu" ]; then
  echo
  echo "## Limits"
  echo
  [ -n "$memory" ] && echo "- memory: $memory (your processes, not your nix builds)"
  [ -n "$cpu" ] && echo "- CPU: $cpu"
fi
