# Owner-only loopback gates for every agent port: each root-held port
# (hlib.forwards: dashboard, Camofox) and its owner-bound backend answer
# the owner and root only; any other uid (another agent included) gets a
# reset. Consumers append gates for their own ports to the same chain
# (hlib.chain).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hermes-native;
  hlib = import ./lib.nix { inherit lib; };
  inherit (hlib) chain;

  ownerOnlyRules = port: user: ''
    iptables -w -A ${chain} -p tcp --dport ${toString port} -m owner --uid-owner ${user} -j RETURN
    iptables -w -A ${chain} -p tcp --dport ${toString port} -m owner --uid-owner 0 -j RETURN
    iptables -w -A ${chain} -p tcp --dport ${toString port} -j REJECT --reject-with tcp-reset
  '';
  # A backend port is base + uid; the uid resolves when the script runs,
  # and iptables takes the number then.
  firewallRules = lib.concatStrings (
    lib.concatLists (
      lib.mapAttrsToList (
        user: _:
        lib.mapAttrsToList (
          _: fwd:
          ownerOnlyRules (fwd.portFor user) user
          + ownerOnlyRules "$((${toString fwd.backendBase} + $(id -u ${user})))" user
        ) hlib.forwards
      ) cfg.users
    )
  );
in
{
  config = lib.mkIf cfg.enable {
    # Owner-match rules ride their own unit, not
    # networking.firewall.extraCommands: the nftables backend refuses
    # extraCommands. `iptables` here is iptables-nft; the rules land in a
    # separate compat table beside the nixos ruleset.
    systemd.services.hermes-firewall = {
      description = "Owner-match loopback firewall for the hermes agents";
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
        iptables -w -N ${chain} 2>/dev/null || true
        iptables -w -F ${chain}
        ${firewallRules}
        iptables -w -C OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j ${chain} 2>/dev/null \
          || iptables -w -A OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j ${chain}
      '';
      preStop = ''
        iptables -w -D OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j ${chain} 2>/dev/null || true
        iptables -w -F ${chain} 2>/dev/null || true
        iptables -w -X ${chain} 2>/dev/null || true
      '';
    };
  };
}
