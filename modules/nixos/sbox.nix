{
  inputs,
  config,
  lib,
  ...
}: {
  imports = [
    inputs.sbox.nixosModules.default
  ];
  programs.direnv.sandbox.enable = true;
  programs.sbox = {
    enable = true;
    allowParent = "off";
    # Bridge host-side omp services into the isolated sandbox netns (default
    # network=isolated uses slirp4netns with --disable-host-loopback, so the
    # sandbox's 127.0.0.1 is NOT the host's). Without this, llama-swap discovery
    # can't reach its host listener.
    allowedTCPPorts =
      lib.optional (config.services.llama-swap.enable or false) config.services.llama-swap.port;
    persist = [
      "$HOME/.claude"
      "$HOME/.pi/agent/sessions"
    ];
    bind = {
      "$HOME/.pi/agent/auth.json" = {};
      "$HOME/.pi/agent/settings.json" = {};
      "$HOME/.omp/agent" = {};
      # omp-sp (pi-superpowers.nix) runs under OMP_PROFILE=sp; its state —
      # including agent.db with the OAuth logins — lives here, not in
      # .omp/agent. Without this bind every sbox launch starts logged out.
      "$HOME/.omp/profiles/sp/agent" = {};
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
    };
  };
}
