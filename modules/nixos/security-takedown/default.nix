/*
  Security takedowns: services the unattended security jobs (or anyone)
  stopped because of a critical, exploitable vulnerability that could not
  be fixed in time (modules/nixos/infra-space/security-jobs/policy.md,
  rule 1). The list is data, ./takedowns.json (JSON, so no computed
  entries: the guard counts what it adds), keyed by machine and unit;
  this module (imported by ../common.nix, so on every machine) disables
  the listed units of its own machine: no start at boot or by
  dependency (`enable = false` drops the unit file), so the switch stops
  a running one.

  An allowlist, not a blocklist: a takedown may only name a unit in its
  machine's `security.takedown.eligible`, the internet-exposed app
  services of that machine (./eligible.nix per machine, or the
  service's own module). Every other unit fails evaluation (an
  assertion, so the build and the deploy fail). Only a session widens
  the list: sec-job-guard refuses changes of ./eligible.nix, of this
  file and of any line naming `takedown.eligible`.

  Also refused at evaluation:
    - a takedowns.json or eligible.nix entry for a machine that does not
      exist (machines/<m>/), instead of being ignored;
    - an eligible unit matching the never-lock-out patterns below
      (policy rule 2: sshd, the mesh, the login path, infra-space, the
      deploy path, DNS/DHCP, networking, firewalls, local login, disk
      unlock, certificates, backups): a second fence for a unit
      declared eligible by mistake.

  Undo: remove the entry, push, deploy that machine.
*/
{
  config,
  lib,
  ...
}:
let
  host = config.networking.hostName;
  all = builtins.fromJSON (builtins.readFile ./takedowns.json);
  eligibleData = import ./eligible.nix;
  mine = all.${host} or { };
  eligible = config.security.takedown.eligible;
  # Every machine of the repo (machines/<m>/), for the unknown-machine check.
  machines = lib.attrNames (
    lib.filterAttrs (_: t: t == "directory") (builtins.readDir ../../../machines)
  );
  unknown = data: lib.filter (m: !(lib.elem m machines)) (lib.attrNames data);
  # Never eligible, as regexes on the unit name; errs on the protected side.
  protected = [
    ".*ssh.*"
    ".*zerotier.*"
    ".*tailscale.*"
    ".*wireguard.*"
    "wg-.*"
    ".*yggdrasil.*"
    ".*tinc.*"
    ".*hyprspace.*"
    ".*mycelium.*"
    ".*cloudflare.*"
    ".*mullvad.*"
    ".*pocket-id.*"
    ".*oidc.*"
    "nginx.*"
    "oauth2-proxy.*"
    "container@.*"
    ".*infra-space.*"
    "hermes-.*"
    "nix-.*"
    "systemd-.*"
    ".*network.*"
    "NetworkManager.*"
    "dhcpcd.*"
    "kea.*"
    "dnsmasq.*"
    "unbound.*"
    "resolvconf.*"
    ".*dnscrypt.*"
    "coredns.*"
    "knot.*"
    ".*nftables.*"
    ".*firewall.*"
    "dbus.*"
    "polkit.*"
    "getty.*"
    "user@.*"
    "user-runtime-dir@.*"
    "greetd.*"
    "display-manager.*"
    "clan-.*"
    ".*tang.*"
    ".*clevis.*"
    ".*unlock.*"
    "zfs-.*"
    "acme-.*"
    ".*dyndns.*"
    ".*backup.*"
    "borgbackup.*"
    "storagebox.*"
    "alloy.*"
    "home-assistant.*"
  ];
  isProtected = unit: lib.any (p: builtins.match p unit != null) protected;
  serviceName = unit: lib.removeSuffix ".service" unit;
in
{
  options.security.takedown.eligible = lib.mkOption {
    type = lib.types.listOf (lib.types.strMatching "[A-Za-z0-9@_.-]+\\.service");
    default = [ ];
    description = ''
      Units of this machine a security takedown
      (modules/nixos/security-takedown/takedowns.json) may stop: its
      internet-exposed app services, nothing else. Set in
      modules/nixos/security-takedown/eligible.nix or by the service's
      module; never by the unattended jobs (sec-job-guard refuses it).
    '';
  };

  config = {
    security.takedown.eligible = eligibleData.${host} or [ ];

    assertions = [
      {
        assertion = unknown all == [ ];
        message = "security-takedown: takedowns.json names unknown machine(s): ${toString (unknown all)} (machines/: ${toString machines})";
      }
      {
        assertion = unknown eligibleData == [ ];
        message = "security-takedown: eligible.nix names unknown machine(s): ${toString (unknown eligibleData)}";
      }
    ]
    ++ map (unit: {
      assertion = !isProtected unit;
      message = "security-takedown: ${host}'s ${unit} is declared takedown-eligible but Dave needs it to reach and repair machines (policy rule 2): drop it from security.takedown.eligible";
    }) eligible
    ++ lib.mapAttrsToList (unit: _: {
      assertion = lib.elem unit eligible;
      message = "security-takedown: ${host}'s ${unit} is not takedown-eligible (security.takedown.eligible: ${toString eligible}): mitigate narrowly and tell Dave instead";
    }) mine
    ++ lib.mapAttrsToList (unit: t: {
      assertion = lib.hasSuffix ".service" unit && t ? reason && t ? since && t ? undo;
      message = "security-takedown: ${host}'s entry ${unit} needs a .service name and reason, since, undo";
    }) mine;

    systemd.services = lib.mapAttrs' (
      unit: _: lib.nameValuePair (serviceName unit) { enable = lib.mkForce false; }
    ) (lib.filterAttrs (unit: _: lib.elem unit eligible && !isProtected unit) mine);
  };
}
