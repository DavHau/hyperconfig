# Owner-match firewall: only the owner (and root) may connect to a VM's
# host-side loopback ports; only that VM's qemu uid, the owner, and root
# may reach the spaces bridge. The qemu uid doubles as the guest's egress
# identity toward slirp's host alias.
{ config, lib, ... }:
let
  cfg = config.services.hermes-microvm;
  hlib = import ./lib.nix { inherit lib; };
  inherit (hlib) vmUser;

  ownerOnlyRules = port: uid: ''
    iptables -w -A hermes-microvm -p tcp --dport ${toString port} -m owner --uid-owner ${toString uid} -j RETURN
    iptables -w -A hermes-microvm -p tcp --dport ${toString port} -m owner --uid-owner 0 -j RETURN
    iptables -w -A hermes-microvm -p tcp --dport ${toString port} -j REJECT --reject-with tcp-reset
  '';
  firewallRules = lib.concatStrings (lib.mapAttrsToList (user: ucfg: ''
    ${ownerOnlyRules ucfg.dashboardPort ucfg.uid}
    ${lib.optionalString ucfg.spacesGateway.enable ''
      iptables -w -A hermes-microvm -p tcp --dport ${toString ucfg.spacesPort} -m owner --uid-owner ${vmUser user} -j RETURN
      ${ownerOnlyRules ucfg.spacesPort ucfg.uid}
    ''}
    # This VM's guest egress allowlist (qemu uid = everything the guest
    # sends to slirp's 10.0.2.2): the spaces RETURN above plus DNS for
    # slirp's resolver forwarding; everything else rejected.
    iptables -w -A hermes-microvm -p tcp --dport 53 -m owner --uid-owner ${vmUser user} -j RETURN
    iptables -w -A hermes-microvm -p udp --dport 53 -m owner --uid-owner ${vmUser user} -j RETURN
    iptables -w -A hermes-microvm -m owner --uid-owner ${vmUser user} -j REJECT
  '') cfg.users);
in
{
  config = lib.mkIf cfg.enable {
    networking.firewall.extraCommands = ''
      iptables -w -N hermes-microvm 2>/dev/null || true
      iptables -w -F hermes-microvm
      ${firewallRules}
      iptables -w -C OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j hermes-microvm 2>/dev/null \
        || iptables -w -A OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j hermes-microvm
      iptables -w -C OUTPUT -o lo -p udp -m conntrack --ctstate NEW -j hermes-microvm 2>/dev/null \
        || iptables -w -A OUTPUT -o lo -p udp -m conntrack --ctstate NEW -j hermes-microvm
    '';
    networking.firewall.extraStopCommands = ''
      iptables -w -D OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j hermes-microvm 2>/dev/null || true
      iptables -w -D OUTPUT -o lo -p udp -m conntrack --ctstate NEW -j hermes-microvm 2>/dev/null || true
      iptables -w -F hermes-microvm 2>/dev/null || true
      iptables -w -X hermes-microvm 2>/dev/null || true
    '';
  };
}
