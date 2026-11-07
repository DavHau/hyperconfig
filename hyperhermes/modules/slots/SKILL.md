---
name: container-slot
description: Your own NixOS container (slot) on this host, with @summary@. Use to run a server or service of your own, deploy a NixOS system with nixos-rebuild, or when the slot is off, unreachable or locked you out.
---

# Your container slot

You own one NixOS container on this host, named after your account. You
deploy any NixOS system into it; it reaches the internet, never this host,
its LAN or other slots. What it connects to leaves through @egress@;
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
@v6reach@@reach@
## Deploy

From a flake on this host:

    nixos-rebuild switch --flake .#slot \
      --target-host root@<v4> --build-host root@<v4>

Builds run on this host's nix daemon. The guest config must import
`nixosModules.slot` from hyperconfig (`github:DavHau/hyperconfig`): it
sets `boot.isNspawnContainer = true;`, sshd with your key (the host
provides it at /var/lib/container-slot/authorized_keys) and the host key
this host provides, plus tool cache defaults. Keep sshd and that key, or
you lock yourself out (then `slot reset`): your ssh checks the host key
and refuses a slot that presents another. Addresses, routes and DNS come
from the host: do not configure networking. Minimal flake:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.hyperconfig.url = "github:DavHau/hyperconfig";
  outputs = { nixpkgs, hyperconfig, ... }: {
    nixosConfigurations.slot = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        hyperconfig.nixosModules.slot
        {
          networking.firewall.allowedTCPPorts = [ 80 443 ];
          system.stateVersion = "25.11";
        }
      ];
    };
  };
}
```
@website@@storage@
## Limits

Memory and CPU of the slot are capped (default 4G, 4 cores), and all slots
together share a further cap, so do not count on free memory beyond yours;
nix builds for it run outside that cap but share this host. Do not use the
slot to scan or attack others.
