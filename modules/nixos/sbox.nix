{
  inputs,
  ...
}: {
  imports = [
    inputs.sbox.nixosModules.default
  ];

  programs.direnv.sandbox.enable = true;
  programs.sbox = {
    enable = true;
    allowParent = "off";
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
      # cctl: DB (rw) + tmux socket for session management
      "$HOME/.config/cctl" = {};
      "/tmp/tmux-$UID" = {};
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
