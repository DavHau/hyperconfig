---
name: esphome
description: Build and flash (OTA) ESPHome firmware for the devices in Roman's homes playa and casa. Use when changing a device's ESPHome config, updating its firmware, or when a device needs a rebuild after an ESPHome change.
---

# ESPHome firmware for playa and casa

Firmware is built here, on this machine, with the `esphome` CLI, and
uploaded over the network (OTA) straight to the device. Never build or
upload from the Home Assistant Pis (no ESPHome Device Builder add-on
installs, no builds over ssh on them): they are too small, and the
configs there are no longer kept up to date.

## Where things are

- `~/esphome/` is a git repo with one directory per home:
  `~/esphome/playa/` (LAN 192.168.10.0/24) and `~/esphome/casa/`
  (LAN 192.168.20.0/24).
- `~/esphome/<site>/README.md` lists every device Home Assistant knows
  there, with its IP and whether a config for it exists here. Devices
  without a config cannot be rebuilt; do not write one from scratch
  without asking Roman (a new config must keep the device's name, API
  encryption key and OTA password, or Home Assistant loses it).
- `~/esphome/<site>/secrets.yaml` holds the Wi-Fi credentials
  (`!secret wifi_ssid` etc.). It is not in git and must stay 0600.
- `~/esphome/<site>/.esphome` is a symlink into `~/scratch` (build
  output); the compilers and frameworks are in `~/.cache`. Both are
  rebuildable, and the first build of a site downloads about 1 GB.

## Secrets

`secrets.yaml` and the inline `api: encryption: key:` and `ota:`
passwords in the YAML files are secrets. Never paste them into chat,
logs you share, or commit messages, and never print the files whole:
use `grep -v -i -E 'key|password|ssid'` or show only the lines you need.

## Workflow

Run everything from the site directory, e.g. `cd ~/esphome/playa`.

1. Edit the device's YAML. Check it:
   `esphome config <file>.yaml >/dev/null || esphome config <file>.yaml | grep -v -i -E 'key|password|ssid|psk'`
   (silent when valid; on failure the second run shows the errors with the
   secret lines filtered out, since the full output contains secrets).
2. Build: `esphome compile <file>.yaml`. A first build takes a few
   minutes, later ones seconds.
3. Upload over the network:
   `esphome upload <file>.yaml --device <ip>`, with the IP from the
   site's README (or Home Assistant's MCP). The device reboots and is
   gone for 10-30 s. mDNS names (`<name>.local`) do not resolve from
   here; always pass the IP.
4. Confirm in Home Assistant (MCP `ha-playa` / `ha-casa`) that the
   device's entities are available again.
5. Commit: `git add <file>.yaml && git commit -m "<device>: <what changed>"`.
   Never commit `secrets.yaml`; there is no remote, the repo is the
   backup.

`esphome run <file>.yaml --device <ip>` does steps 2 and 3 in one go.

Before uploading, make sure the device at that IP is the one the config
is for (Home Assistant's device name and IP match the README): the same
switch can appear at both sites, and uploading one site's config to a
device at the other replaces its settings. If the device is unavailable
in Home Assistant, do not upload; report it instead.

## When something fails

- `Connection refused`/timeout on upload: the device is off or has a new
  IP; look it up in Home Assistant. Nothing is flashed until the upload
  connects.
- `Disk quota exceeded`: see the `storage` skill; old build dirs under
  `~/scratch/esphome/` can be deleted (`esphome clean <file>.yaml`).
- Version: the `esphome` here can be a release behind the Home Assistant
  add-on; a config using a brand-new option may fail to validate. Say so
  rather than rewriting the config around it.
