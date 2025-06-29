{ config, pkgs, lib, ... }: {
  home.activation.boforeCheckLinkTargets = {
    after = [];
    before = [ "checkLinkTargets" ];
    data = ''
      for userDir in /home/grmpf/.config/Code/User; do
        rm -rf $userDir/settings.json
      done
    '';
  };

  home.activation.afterWriteBoundary = {
    after = [ "writeBoundary" ];
    before = [];
    data = ''
      for userDir in /home/grmpf/.config/Code/User; do
        rm -rf $userDir/settings.json
        cat \
          ${(pkgs.formats.json {}).generate "blabla"
            config.programs.vscode.userSettings} \
          > $userDir/settings.json
      done
    '';
  };

  programs.vscode.mutableExtensionsDir = false;
  programs.vscode = {
    enable = true;
    package = pkgs.vscode;
    extensions = with pkgs.vscode-extensions; [
      jnoortheen.nix-ide
      ms-pyright.pyright
      eamodio.gitlens
      github.copilot
      github.copilot-chat
      tomoki1207.pdf
      twxs.cmake
      streetsidesoftware.code-spell-checker
      ms-python.python
      # ms-vscode.cmake-tools
      llvm-vs-code-extensions.vscode-clangd
      # ms-vscode-remote.remote-containers
      # mkhl.direnv
      # editorconfig.editorconfig
      # davidanson.vscode-markdownlint
      # timonwong.shellcheck
      # bungcip.better-toml
      # ms-vscode.cpptools
      # dbaeumer.vscode-eslint
      # esbenp.prettier-vscode
      # vscodevim.vim
      # (pkgs.vscode-utils.buildVscodeMarketplaceExtension {
      #   mktplcRef = {
      #     name = "markdowntable";
      #     publisher = "TakumiI";
      #     version = "0.11.0";
      #     sha256 = "sha256-kn5aLRaxxacQMvtTp20IdTuiuc6xNU3QO2XbXnzSf7o=";
      #   };
      # })

      # ms-python.vscode-pylance
      # ms-vsliveshare.vsliveshare
      # bradlc.vscode-tailwindcss
      # jock.svg
      # denoland.vscode-deno
      # justusadam.language-haskell
      # haskell.haskell
      # rust-lang.rust-analyzer
      # ms-toolsai.jupyter
      # arrterian.nix-env-selector
      # arrterian.nix-env-selector
      # serayuzgur.crates
      # tamasfe.even-better-toml
      # coenraads.bracket-pair-colorizer-2
      # esbenp.prettier-vscode
      # emmanuelbeziat.vscode-great-icons
    ];

    userSettings = {
      "files.autoSave" = "onFocusChange";
      "files.insertFinalNewline" = true;
      "files.trimTrailingWhitespace" = true;
      "[markdown]"."files.trimTrailingWhitespace" = false;
      "update.mode" = "none"; # updates are done by nix
      "explorer.confirmDelete" = false;
      "editor.tabSize" = 2;
      "editor.rulers" = [ 80 88 120 ];
      # "editor.fontSize" = 20;
      "editor.lineNumbers" = "interval";
      "editor.cursorBlinking" = "solid";
      # "editor.fontFamily" = "Fira Code";
      # "editor.fontLigatures" = true;
      # "editor.fontWeight" = "400";
      # "editor.formatOnSave" = true;
      # "editor.formatOnPaste" = true;
      "breadcrumbs.enabled" = true;
      "terminal.integrated.scrollback" = 10000;
      # git
      "git.confirmSync" = false;
      "git.autofetch" = false;
      "magit.code-path" = "codium";
      "nix.enableLanguageServer" = true;
      "nix.serverPath" = "nil";
      "rust-analyzer.check.command" = "clippy";

      # deno
      "deno.enable" = true;

      # vim
      "vim.useCtrlKeys" = false;

      # sticky scroll
      "notebook.stickyScroll.enabled" = true;
      "editor.stickyScroll.enabled" = true;

      # spell checking everywhere
      "cSpell.checkOnlyEnabledFileTypes" = false;

      # font
      "editor.fontFamily" = "FiraCode Nerd Font, monospace";
      "editor.fontLigatures" = true;
      "workbench.iconTheme" = "material-icon-theme";
    };

    keybindings = [
      { command = "editor.action.duplicateSelection";
        key = "Ctrl+D"; }
      { command = "editor.action.toggleColumnSelection";
        key = "Shift+Alt+Insert"; }
      { command = "copyRelativeFilePath";
        key = "Ctrl+Shift+Alt+C";
        when = "editorFocus";}
      { command = "github.copilot.acceptCursorPanelSolution";
        key = "Ctrl+Shift+/";}
      {
        command = "git.commitAmend";
        key = "ctrl+alt+c ctrl+alt+a";
      }
    ];
  };
}
