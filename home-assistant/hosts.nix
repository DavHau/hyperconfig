# Roman's two Home Assistant instances (HA OS, not clan machines), as the
# state `nix run .#home-assistant-apply` converges them to
# (../modules/flake-parts/apps.home-assistant-apply.nix, ./remote.py).
# Plain data: rendered to JSON as it stands and shipped to each instance.
#
# Reached over the zerotier "home" net (../machines/som/roman-home-assistant.nix
# says which addresses and why): ssh lands in the SSH add-on, whose shell
# holds the Supervisor token for the Supervisor and Core APIs.
{ self, lib }:
let
  # Root keys of every clan machine: the sshd instance's authorizedKeys
  # (../modules/flake-parts/nixosConfigurations.nix), read through the
  # option it sets so the module wrapping of inventory settings stays opaque.
  adminKeys = lib.attrValues
    (lib.evalModules {
      modules = [
        { options.authorizedKeys = lib.mkOption { type = lib.types.attrsOf lib.types.str; }; }
        self.clan.inventory.instances.sshd.roles.server.settings
      ];
    }).config.authorizedKeys;

  instance = name: {
    # Core as seen from inside the add-on (login flow, the user's own
    # websocket); the Supervisor proxies only /api and the admin websocket.
    coreUrl = "http://homeassistant:8123";

    addons = {
      # "Advanced SSH & Web Terminal" (community repository). The session
      # runs in it, so remote.py changes its own options last and restarts it
      # detached.
      a0d7b954_ssh = {
        present = true;
        repository = "https://github.com/hassio-addons/repository";
        started = true;
        boot = "auto";
        network."22/tcp" = 22;
        options = {
          ssh = {
            username = "root";
            password = "";
            authorized_keys = adminKeys;
            sftp = false;
            compatibility_mode = false;
            allow_agent_forwarding = false;
            allow_remote_port_forwarding = false;
            allow_tcp_forwarding = false;
          };
          zsh = true;
          share_sessions = false;
          packages = [ ];
          init_commands = [ ];
        };
      };
      # The official SSH add-on: replaced by the one above.
      core_ssh.present = false;
    };

    # Roman's hermes agent on som (../machines/som/roman-home-assistant.nix):
    # MCP only, as this non-admin user. It has no password: apply mints its
    # long-lived token through a throwaway one and removes that again.
    users.hermes-roman = {
      group_ids = [ "system-users" ];
      local_only = true;
      is_active = true;
      token = {
        machine = "som";
        var = "ha-${name}-token/token";
        clientName = "hermes-roman (hyperconfig)";
        lifespanDays = 3650;
      };
    };

    # "Model Context Protocol Server" (mcp_server, single entry): the Assist
    # API only, open to non-admins so hermes-roman can use it.
    configEntries.mcp_server.options = {
      all_llm_apis = false;
      llm_hass_api = [ "assist" ];
      require_admin = false;
      read_only = false;
    };
  };
in
{
  playa = instance "playa" // {
    address = "192.168.194.30";
    sshPort = 22;
  };
  casa = instance "casa" // {
    address = "fcc0:044a:8669:8c81:6d54::1";
    sshPort = 22;
  };
}
