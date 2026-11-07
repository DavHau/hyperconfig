---
name: esphome
description: Build and OTA-flash ESPHome firmware for the devices at playa and casa. Use when changing a device's config or updating its firmware.
---

- Configs: `~/esphome/<site>/` (a git repo, no remote); each site's
  README lists the known devices. Don't write configs from scratch without
  asking Roman.
- Build here with `esphome`, upload by IP:
  `esphome run <file>.yaml --device <ip>`. Never build on the Home
  Assistant hosts.
- Before uploading, confirm the device at that IP is the one the config is
  for and is available in Home Assistant; afterwards confirm it is back.
- `secrets.yaml` and the `api`/`ota` keys in the YAMLs are secrets: never
  show them; filter output (`grep -v -i -E 'key|password|ssid|psk'`).
- Commit config changes in `~/esphome`.
