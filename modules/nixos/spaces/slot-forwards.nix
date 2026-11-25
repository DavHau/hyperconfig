/*
  The mesh way into the container slots of ./slots.nix on this machine:
  [<this host's yggdrasil address>]:<sshPort> forwarded to the slot's sshd
  on its public v6 (<ipv6Prefix>::5107:<id hex>, container-slots), like a
  space's ssh forward (./host.nix): a socket-activated
  systemd-socket-proxyd under a dynamic user, the port opened on the mesh
  interface only. So Dave's desktops reach the slot over the mesh
  (./client.nix, alias `<slot>-<machine>`) from any network, not over the
  slot's public v6, which a v4-only network (amy on a hotspot) lacks.

  The slot's sshd authenticates as before (its own authorized keys); this
  adds no login, only a second path to the same port 22. Who reaches it:
  the fleet's mesh addresses (som's yggdrasil filter drops every other
  mesh peer) and every local uid here, as the spaces' forwards
  (./host.nix): also the agents that ../zt-eu-lan-guard keeps off the
  slot's LAN address, since the hop to this host's own mesh address is
  local. They still need a key the slot authorizes. The slot sees every
  such login come from this host's address.

  Only where container-slots is imported (som): a host without it (the
  spaces VM test's) gets nothing from this file.
*/
{ config, options, lib, ... }:
let
  machine = config.clan.core.settings.machine.name;
  container-slots = config.services.container-slots;
  meshAddress = config.clan.core.vars.generators.yggdrasil.files.address.value;
  slotAddress =
    name: "${container-slots.ipv6Prefix}::5107:${lib.toLower (lib.toHexString container-slots.slots.${name}.id)}";
in
{
  config = lib.mkMerge (
    # Over every slot, each behind mkIf: the list's shape must not depend
    # on config (the machine's name), or the module system recurses; the
    # option tree (`options`) is safe to ask.
    lib.optionals (options.services ? container-slots) (lib.mapAttrsToList (name: s: lib.mkIf (s.machine == machine) {
      systemd.sockets."slot-${name}-ssh" = {
        description = "${name} slot's sshd on the mesh address";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "[${meshAddress}]:${toString s.sshPort}" ];
        # No BindToDevice: it would tie the socket to the ygg device,
        # which appears only after yggdrasil starts (boot stalls on it, a
        # yggdrasil restart stops the socket), and local delivery to the
        # mesh address passes it anyway.
        socketConfig.FreeBind = true;
      };
      systemd.services."slot-${name}-ssh" = {
        description = "Forward to the ${name} slot's sshd";
        serviceConfig = {
          # Unbracketed: systemd-socket-proxyd resolves the target with
          # getaddrinfo on the part before the last colon, so `[v6]:22`
          # fails ("Failed to resolve host") and `v6:22` works (tested
          # with systemd 262 on som).
          ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd ${slotAddress name}:22";
          DynamicUser = true;
          PrivateTmp = true;
        };
      };
      networking.firewall.interfaces.ygg.allowedTCPPorts = [ s.sshPort ];
    }) (import ./slots.nix))
  );
}
