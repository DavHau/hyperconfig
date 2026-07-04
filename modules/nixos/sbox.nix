{
  inputs,
  config,
  lib,
  ...
}: let
  dual = config.services.omp-dual-anthropic;
in {
  imports = [
    inputs.sbox.nixosModules.default
  ];
  programs.direnv.sandbox.enable = true;
  programs.sbox = {
    enable = true;
    allowParent = "off";
    # Bridge host-side omp services into the isolated sandbox netns (default
    # network=isolated uses slirp4netns with --disable-host-loopback, so the
    # sandbox's 127.0.0.1 is NOT the host's). Without these, the custom
    # anthropic-main/anthropic-sub gateway providers (and llama-swap discovery)
    # can't reach their host listeners.
    allowedTCPPorts =
      lib.optionals dual.enable [ dual.mainAccount.gatewayPort dual.subAccount.gatewayPort ]
      ++ lib.optional (config.services.llama-swap.enable or false) config.services.llama-swap.port;
    persist = [
      "$HOME/.claude"
      "$HOME/.pi/agent/sessions"
    ];
    bind = {
      "$HOME/.pi/agent/auth.json" = {};
      "$HOME/.pi/agent/settings.json" = {};
      "$HOME/.omp/agent" = {};
      "$HOME/.local/share/zoxide" = {};
      "$HOME/.local/share/pueue" = {};
      "$XDG_RUNTIME_DIR/pueue_$USER.socket" = {};
      "$HOME/.claude/.credentials.json" = {};
      "$HOME/.claude.json" = {};
      # VSCode state/config (caches, workspaces, settings, etc.)
      "$HOME/.config/Code" = {};
      "$HOME/synced/projects" = {};
      "$HOME/projects" = {};
      # cctl: DB + notify.sock (rw) for the in-sandbox agent hooks. The host
      # tmux socket dir is intentionally NOT bound: sbox gives /tmp its own
      # tmpfs, so a tmux server started inside a sandbox stays private to that
      # sandbox rather than joining (and exposing) the host's tmux server.
      "$HOME/.config/cctl" = {};
    };
    bindReadOnly = {
      "$HOME/.pi/agent/skills" = {};
      "$HOME/.pi/agent/extensions" = {};
      "$HOME/.pi/agent/models.json" = {};
      "$HOME/.pi/agent/AGENTS.md" = {};
      "$HOME/.ssh/id_ed25519_github1".to = "$HOME/.ssh/id_ed25519";
      "$HOME/.ssh/id_ed25519_github1.pub".to = "$HOME/.ssh/id_ed25519.pub";
      # VSCode extensions (nix-managed) and CLI
      "$HOME/.vscode" = {};
      "$HOME/.config/pueue" = {};
      # Gateway bearer tokens for the dual-anthropic providers. models.yml
      # resolves each provider's apiKey via `!cat $HOME/.omp/profiles/<p>/auth-gateway.token`;
      # without this bind those files are absent in the sandbox and the custom
      # anthropic providers resolve to an empty key -> dropped from availability.
      "$HOME/.omp/profiles" = {};
    };
  };
}
