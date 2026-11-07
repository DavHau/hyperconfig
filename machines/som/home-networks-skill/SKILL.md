---
name: home-networks
description: Roman's two home networks (playa, casa) and their Home Assistant instances; read before touching devices there.
---

som routes directly into both home LANs:

| site | LAN | Home Assistant |
|---|---|---|
| playa | 192.168.10.0/24, fd2a:8abf:35da::/48 | 192.168.10.3:8123 |
| casa | 192.168.20.0/24, fd99:a769:4eae::/48 | 192.168.20.3:8123 |

- Home Assistant: the `ha-playa` / `ha-casa` MCP servers if you have them;
  for everything else the REST/WebSocket API with `$HA_PLAYA_TOKEN` /
  `$HA_CASA_TOKEN` (admin) if set. Otherwise you have no HA credentials.
- ESPHome devices: see the `esphome` skill if you have it. Never build
  firmware on the Home Assistant hosts.
