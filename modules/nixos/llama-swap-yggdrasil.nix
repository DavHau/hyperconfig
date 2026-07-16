# Expose llama-swap to the other clan machines over yggdrasil.
#
# The base module (spaces) already binds 0.0.0.0:<port>; only the firewall
# gates remote access. Opening the port on the `ygg` interface makes the
# OpenAI-compatible endpoint reachable via this machine's `<host>.d` name
# (yggdrasil IPv6 from the clan-generated /etc/hosts) — e.g. amy's hermes
# VMs talk to qwen3.6 on vit through http://vit.d:8012/v1.
#
# Yggdrasil-scoped on purpose: LAN/WAN interfaces stay closed, and the
# clan controls who peers on ygg (AllowedEncryptionPublicKeys).
{ config, ... }:
{
  networking.firewall.interfaces.ygg.allowedTCPPorts = [
    config.services.llama-swap.port
  ];
}
