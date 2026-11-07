---
name: esphome
description: Build and OTA-flash ESPHome firmware for the devices at playa and casa. Use when changing a device's config or updating its firmware.
---

- Configs: `~/esphome/<site>/` (git repo); each site's README lists the
  known devices.
- Build here with `esphome`, never on the Home Assistant hosts; upload by
  IP: `esphome run <file>.yaml --device <ip>`.
