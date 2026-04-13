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
      "$HOME/.omp/agent/sessions"
    ];
    bind = {
      "$HOME/.pi/agent/auth.json" = {};
      "$HOME/.pi/agent/settings.json" = {};
      "$HOME/.omp/agent/agent.db" = {};
      "$HOME/.local/share/zoxide" = {};
      "$HOME/.claude/.credentials.json" = {};
      # VSCode state/config (caches, workspaces, settings, etc.)
      "$HOME/.config/Code" = {};
      "$HOME/synced/projects" = {};
      "$HOME/projects" = {};
    };
    bindReadOnly = {
      "$HOME/.pi/agent/skills" = {};
      "$HOME/.pi/agent/extensions" = {};
      "$HOME/.pi/agent/models.json" = {};
      "$HOME/.pi/agent/AGENTS.md" = {};
      "$HOME/.omp/agent/skills" = {};
      "$HOME/.omp/agent/extensions" = {};
      "$HOME/.omp/agent/models.json" = {};
      "$HOME/.omp/agent/AGENTS.md" = {};
      "$HOME/.ssh/id_ed25519_github1".to = "$HOME/.ssh/id_ed25519";
      "$HOME/.ssh/id_ed25519_github1.pub".to = "$HOME/.ssh/id_ed25519.pub";
      # VSCode extensions (nix-managed) and CLI
      "$HOME/.vscode" = {};
    };
  };
}
