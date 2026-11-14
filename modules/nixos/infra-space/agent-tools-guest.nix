/*
  The infra agent's side of ./agent-tools.nix (the host serves; som only):
  every tool dials the host's veth address, and inside the guest only
  infra and root may (the output gate below; the dashboard and voice
  proxies' uids and any other guest user cannot).
    - mailgate: /run/mailgate/agent.sock here (0600 infra), proxied to the
      host's, where it answers as the mailbox infra@<domain>; the `mailgate`
      CLI and skill unchanged. himalaya (IMAP backend only) logs into the
      host's IMAP with the credential `mail-imap`.
    - browser, only with `browser` (the host's
      hyper.infraSpace.agentTools.browser, default off): hyperhermes'
      camofox plugin as a bundled plugin of the package (plugins/ is
      locked empty, ./hermes.nix), CAMOFOX_URL the host's port,
      CAMOFOX_API_KEY the credential `camofox-key`, toolset `camofox` on
      every platform. The server runs on the host as its own user:
      nothing it loads reaches this filesystem. Off, none of that exists
      (no plugin, no CAMOFOX_* variables, no key) and `camofox` is in
      agent.disabled_toolsets besides (./hermes.nix): hermes turns a
      plugin's toolset on by default wherever it is installed
      (hermes_cli/tools_config.py _enabled_plugin_toolsets), so the cap is
      the second line. Web pages are prompt injection aimed at an agent
      holding fleet root: when on, browse only in a delegated child
      (delegate_task) whose goal is the browsing, never in the parent's
      own turns. A rule for the agent, not enforced: hermes (the
      hyperhermes `hermes-agent` input) builds every child with the
      parent's toolsets (tools/delegate_tool.py), so a toolset cannot be
      given to children only.
    - wallet: `lnwallet` (phoenix-cli) against the host's port, its
      password the credential `phoenix.conf` (PHOENIX_DATADIR is the
      secrets directory, so the password is never on a command line).
*/
{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.infraSpace.agentTools;
  secretsDir = "/run/infra-space/secrets";
  user = "infra";

  himalayaConfig = (pkgs.formats.toml { }).generate "himalaya-infra.toml" {
    accounts.${user} = {
      default = true;
      email = "${user}@${cfg.mailDomain}";
      imap = {
        server = "imap://${cfg.vethHost}:${toString cfg.imapPort}";
        starttls = false;
        sasl.plain = {
          username = user;
          password.command = [
            "${pkgs.coreutils}/bin/cat"
            "${secretsDir}/mail-imap"
          ];
        };
      };
      mailbox.alias.inbox = "INBOX";
    };
  };
  himalaya = pkgs.writeShellScriptBin "himalaya" ''
    export HIMALAYA_CONFIG=${himalayaConfig}
    exec ${cfg.himalaya}/bin/himalaya "$@"
  '';
  lnwallet = pkgs.writeShellScriptBin "lnwallet" ''
    export PHOENIX_DATADIR=${secretsDir}
    exec ${cfg.phoenixd}/bin/phoenix-cli --http-bind-ip=${cfg.vethHost} --http-bind-port=${toString cfg.walletPort} "$@"
  '';

  # The package with the camofox plugin among its bundled plugins: core's
  # default package (the option's default, so no recursion through
  # config), its plugins/ extended.
  basePackage = options.services.hyperhermes.package.default;
  bundledPlugins = pkgs.runCommand "hermes-plugins-with-camofox" { } ''
    mkdir $out
    for e in ${basePackage}/share/hermes-agent/plugins/*; do ln -s "$e" $out/; done
    ln -s ${cfg.camofoxPlugin} $out/camofox
  '';
  gatedPorts = lib.concatMapStringsSep "," toString (
    [
      cfg.mailPort
      cfg.imapPort
      cfg.walletPort
    ]
    ++ lib.optional cfg.browser cfg.browserPort
  );
in
{
  options.infraSpace.agentTools = {
    enable = lib.mkEnableOption "the infra agent's mailbox, browser and wallet on the host (./agent-tools.nix)";
    vethHost = lib.mkOption { type = lib.types.str; };
    mailPort = lib.mkOption { type = lib.types.port; };
    imapPort = lib.mkOption { type = lib.types.port; };
    walletPort = lib.mkOption { type = lib.types.port; };
    browserPort = lib.mkOption { type = lib.types.port; };
    mailDomain = lib.mkOption { type = lib.types.str; };
    mailgate = lib.mkOption { type = lib.types.package; };
    himalaya = lib.mkOption { type = lib.types.package; };
    mailSkill = lib.mkOption { type = lib.types.package; };
    walletSkill = lib.mkOption { type = lib.types.package; };
    phoenixd = lib.mkOption { type = lib.types.package; };
    camofoxPlugin = lib.mkOption { type = lib.types.package; };
    browser = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "The camofox plugin, its credential and toolset (the agent's and so its children's); see the header.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf cfg.browser {
        # Core's package links share/hermes-agent/plugins to its patched
        # plugins in ITS postInstall (hyperhermes modules/core/package.nix);
        # ours is appended after it, so this link wins. The assertion below
        # fails the eval should core stop making that link there (then ours
        # might be overwritten, or core's patched plugins dropped).
        assertions = [
          {
            assertion =
              lib.hasInfix "/share/hermes-agent/plugins" (basePackage.postInstall or "")
              && !lib.hasInfix "/share/hermes-agent/plugins" (basePackage.postFixup or "");
            message = "infraSpace.agentTools: core's hermes package no longer links share/hermes-agent/plugins in its postInstall; re-check the camofox plugin override in ./agent-tools-guest.nix.";
          }
        ];
        services.hyperhermes.package = lib.mkForce (
          basePackage.overrideAttrs (old: {
            postInstall = (old.postInstall or "") + ''
              ln -sfn ${bundledPlugins} $out/share/hermes-agent/plugins
            '';
          })
        );

        infraSpace.hermes.extraToolsets = [ "camofox" ];

        services.hyperhermes.agents.${user} = {
          environment.CAMOFOX_URL = "http://${cfg.vethHost}:${toString cfg.browserPort}";
          secretEnv.CAMOFOX_API_KEY = "/run/credentials/@system/camofox-key";
          # What hyperhermes' browser module sets for an agent's Camofox
          # (its camofox.nix), and the left-core migration marked done: the
          # plugin is bundled here, so there is nothing to install.
          settings = {
            browser = {
              cloud_provider = "camofox";
              camofox.managed_persistence = true;
              command_timeout = 65;
            };
            plugins = {
              enabled = [ "camofox" ];
              auto_apply = false;
            };
            webapp.enabled = false;
            _left_core_installed = [ "camofox" ];
          };
        };
      })
      {
        infraSpace.hermes.extraSkills = [
          cfg.mailSkill
          cfg.walletSkill
        ];
        services.hyperhermes.agents.${user}.extraPackages = [
          cfg.mailgate
          himalaya
          lnwallet
        ];

        # The host's agent socket, here for the mailgate CLI.
        systemd.sockets.infra-mailgate = {
          description = "mailgate agent socket (the host's, for infra)";
          wantedBy = [ "sockets.target" ];
          listenStreams = [ "/run/mailgate/agent.sock" ];
          socketConfig = {
            SocketUser = user;
            SocketMode = "0600";
            DirectoryMode = "0755";
          };
        };
        systemd.services.infra-mailgate = {
          description = "Forward infra's mailgate socket to the host";
          serviceConfig = {
            ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd ${cfg.vethHost}:${toString cfg.mailPort}";
            User = user;
            PrivateTmp = true;
          };
        };

        # Only infra and root dial the host's tool ports.
        systemd.services.infra-agent-tools-firewall = {
          description = "Only infra and root reach the host's agent tools";
          wantedBy = [ "multi-user.target" ];
          after = [
            "firewall.service"
            "userborn.service"
          ];
          partOf = [ "firewall.service" ];
          path = [ pkgs.iptables ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            iptables -w -N infra-agent-tools 2>/dev/null || true
            iptables -w -F infra-agent-tools
            iptables -w -A infra-agent-tools -m owner --uid-owner ${user} -j RETURN
            iptables -w -A infra-agent-tools -m owner --uid-owner 0 -j RETURN
            # tcp-reset needs -p tcp; only tcp jumps here
            iptables -w -A infra-agent-tools -p tcp -j REJECT --reject-with tcp-reset
            iptables -w -C OUTPUT -d ${cfg.vethHost} -p tcp -m multiport --dports ${gatedPorts} -m conntrack --ctstate NEW -j infra-agent-tools 2>/dev/null \
              || iptables -w -I OUTPUT -d ${cfg.vethHost} -p tcp -m multiport --dports ${gatedPorts} -m conntrack --ctstate NEW -j infra-agent-tools
          '';
        };
        systemd.services.hermes-agent-infra = {
          after = [ "infra-agent-tools-firewall.service" ];
          wants = [ "infra-agent-tools-firewall.service" ];
        };
      }
    ]
  );
}
