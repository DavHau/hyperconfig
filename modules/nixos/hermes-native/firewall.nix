# Owner-only loopback gates for every agent port: the root-held public
# ports and the owner-bound backends answer the owner and root only; any
# other uid (another agent included) gets a reset. Vendored from spaces
# 6d744780 modules/nixos/hermes/firewall.nix (native rules only). Unit,
# chain name (`hermes-microvm`) and rule text stay spaces', so modules
# that append to the chain (../hermes-agents-serve.nix,
# ../hermes-dashboard-public.nix) work with either module.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hermes-native;
  hlib = import ./lib.nix { inherit lib; };

  ownerOnlyRules = port: user: ''
    iptables -w -A hermes-microvm -p tcp --dport ${toString port} -m owner --uid-owner ${user} -j RETURN
    iptables -w -A hermes-microvm -p tcp --dport ${toString port} -m owner --uid-owner 0 -j RETURN
    iptables -w -A hermes-microvm -p tcp --dport ${toString port} -j REJECT --reject-with tcp-reset
  '';
  # The public simplex port (root-held, hash-derived) and both backend
  # ports (base + uid, bound by the owner's daemons) get the same gate as
  # the public dashboard port. The uid resolves when the script runs;
  # iptables takes the number then.
  nativeRules =
    user: ucfg:
    ownerOnlyRules "$((${toString hlib.nativeDashboardBase} + $(id -u ${user})))" user
    + lib.optionalString cfg.simplex.enable (
      ownerOnlyRules ucfg.simplexPort user
      + ownerOnlyRules "$((${toString hlib.nativeSimplexBase} + $(id -u ${user})))" user
    );
  firewallRules = lib.concatStrings (
    lib.mapAttrsToList (user: ucfg: ''
      ${ownerOnlyRules ucfg.dashboardPort user}
      ${nativeRules user ucfg}
    '') cfg.enabledUsers
  );
in
{
  config = lib.mkIf cfg.enable {
    # Owner-match rules ride their own unit, not
    # networking.firewall.extraCommands: the nftables backend refuses
    # extraCommands. `iptables` here is iptables-nft; the rules land in a
    # separate compat table beside the nixos ruleset.
    systemd.services.hermes-firewall = {
      description = "Owner-match loopback firewall for hermes microvms";
      wantedBy = [ "multi-user.target" ];
      # Username owner-match rules require the users to exist at insert
      # time; iptables resolves the names then. Both firewall backends
      # flush at start (nftables.service runs `flush ruleset`, which drops
      # the compat table too), so this unit comes after them and
      # re-inserts whenever they restart.
      after = [
        "userborn.service"
        "firewall.service"
        "nftables.service"
      ];
      partOf =
        lib.optional config.networking.nftables.enable "nftables.service"
        ++ lib.optional (!config.networking.nftables.enable) "firewall.service";
      path = [
        pkgs.iptables
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        iptables -w -N hermes-microvm 2>/dev/null || true
        iptables -w -F hermes-microvm
        ${firewallRules}
        iptables -w -C OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j hermes-microvm 2>/dev/null \
          || iptables -w -A OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j hermes-microvm
        iptables -w -C OUTPUT -o lo -p udp -m conntrack --ctstate NEW -j hermes-microvm 2>/dev/null \
          || iptables -w -A OUTPUT -o lo -p udp -m conntrack --ctstate NEW -j hermes-microvm
      '';
      preStop = ''
        iptables -w -D OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j hermes-microvm 2>/dev/null || true
        iptables -w -D OUTPUT -o lo -p udp -m conntrack --ctstate NEW -j hermes-microvm 2>/dev/null || true
        iptables -w -F hermes-microvm 2>/dev/null || true
        iptables -w -X hermes-microvm 2>/dev/null || true
      '';
    };
  };
}
