---
name: container-slot
description: Your own NixOS container (slot) on this host, with a public IPv6, a hostname and 10 public IPv4 TCP ports. Use to run a server or service of your own, deploy a NixOS system with nixos-rebuild, or when the slot is off, unreachable or locked you out.
---

# Your container slot

You own one NixOS container on this host, named after your account. You
deploy any NixOS system into it; it reaches the internet, never this host,
its LAN or other slots. What it connects to leaves through Mullvad (its
outbound address is a Mullvad one, not its own IPv6 or the public IPv4);
what connects to it arrives directly. Run `slot info` for its addresses,
hostname, ports and the exact deploy command.

## On and off

The slot is off until you start it, and stays as you left it across host
reboots.

- `slot status`: desired state and whether the container runs.
- `slot start` / `slot stop`.
- `slot reset`: stops it, replaces its system with the minimal bootstrap
  system (sshd with your key), then restores the previous on/off state.
  Files in the slot stay. Use it when a deploy broke sshd or your key.
- `slot reset --hard`: the same, and also wipes everything in the slot
  (/root, /var, /etc) and its gc roots and profiles. Last resort. The ssh
  host key stays: this host keeps it.

The slot refuses to start if its /root, /etc, /usr, /usr/bin, /var,
/var/lib or /var/lib/private is a symlink; `slot reset --hard` fixes that.

Each command may run at most 6 times per 10 minutes.

## Reach it

- From this host: `ssh root@<v4>` (only your account gets through, on any
  port; your key and the slot's host key are picked automatically).
- From anywhere: `ssh root@<v6>` and every port on the IPv6 address; the
  slot's own firewall decides what answers.
- `<you>.slots.davhau.com`: AAAA is the slot's IPv6; A is the shared public
  IPv4. This host keeps both records current; there is nothing to set up.
  On that IPv4, ports 80 and 443 reach the slot for this hostname
  only (443 by SNI; TLS ends in your slot, so ACME HTTP-01 and normal
  certificates work). Over IPv4 the slot sees this host as the peer: on 80
  the client address is in X-Real-IP and as the last X-Forwarded-For entry
  (earlier entries are whatever the client sent; do not trust them), on 443
  it is not visible.
- 10 TCP ports on the public IPv4 (`slot info`) forward to the same ports
  in the slot, with the real client address. No UDP over IPv4; use IPv6.

## Deploy

From a flake on this host:

    nixos-rebuild switch --flake .#slot \
      --target-host root@<v4> --build-host root@<v4>

Builds run on this host's nix daemon. The guest config must contain
`boot.isNspawnContainer = true;` and keep sshd with your key and the host
key this host provides, or you lock yourself out (then `slot reset`): your
ssh checks that key and refuses a slot that presents another. Addresses,
routes and DNS come from the host: do not configure networking. Minimal
flake:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { nixpkgs, ... }: {
    nixosConfigurations.slot = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        {
          boot.isNspawnContainer = true;
          services.openssh.enable = true;
          # The host provides your key here; keep this line.
          services.openssh.authorizedKeysFiles = [ "/var/lib/container-slot/authorized_keys" ];
          # The host key this host pins; keep it too.
          services.openssh.hostKeys = [
            { type = "ed25519"; path = "/var/lib/container-slot/ssh_host_ed25519_key"; }
          ];
          networking.firewall.allowedTCPPorts = [ 80 443 ];
          system.stateVersion = "25.11";
        }
      ];
    };
  };
}
```

For a website add nginx with `enableACME = true; forceSSL = true;` on a
virtualHost named `<you>.slots.davhau.com`, plus
`security.acme.acceptTerms = true;` and `security.acme.defaults.email`.

## Limits

Memory and CPU of the slot are capped (default 4G, 4 cores), and all slots
together share a further cap, so do not count on free memory beyond yours;
nix builds for it run outside that cap but share this host. Do not use the
slot to scan or attack others.
