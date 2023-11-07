{ config, pkgs, lib, ... }: let
  l = lib // builtins;
in {

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;

  home-manager.users.grmpf = rec {
    home.stateVersion = "22.11";
    # ich hab kein dunst
    services.dunst.enable = true;
    # udiskie
    services.udiskie.enable = true;
    # it requires a tray target :/
    systemd.user.targets.tray = {
      Unit = {
        Description = "Home Manager System Tray";
        Requires = [ "graphical-session-pre.target" ];
      };
    };

    programs.fish.enable = true;

    programs.alacritty.enable = true;
    programs.alacritty.settings = {
      font.size = 5.5;
    };
    programs.alacritty.package = pkgs.alacritty;

    programs.direnv.enable = true;
    programs.direnv.nix-direnv.enable = true;
    # optional for nix flakes support in home-manager 21.11, not required in home-manager unstable or 22.05

    programs.zoxide.enable = true;

    home.activation.boforeCheckLinkTargets = {
      after = [];
      before = [ "checkLinkTargets" ];
      data = ''
        for userDir in /home/grmpf/.config/{VSCodium,Code}/User; do
          rm -rf $userDir/settings.json
        done
      '';
    };

    home.activation.afterWriteBoundary = {
      after = [ "writeBoundary" ];
      before = [];
      data = ''
        for userDir in /home/grmpf/.config/{VSCodium,Code}/User; do
          rm -rf $userDir/settings.json
          cat \
            ${(pkgs.formats.json {}).generate "blabla"
              programs.vscode.userSettings} \
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
        editorconfig.editorconfig
        davidanson.vscode-markdownlint
        timonwong.shellcheck
        eamodio.gitlens
        ms-vscode.cpptools
        jock.svg
        streetsidesoftware.code-spell-checker
        bungcip.better-toml
        ms-python.python
        mkhl.direnv
        github.copilot
        github.copilot-chat
        ms-python.vscode-pylance
        ms-vsliveshare.vsliveshare
        ms-vscode.cpptools
        ms-vscode.cmake-tools
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
        "editor.rulers" = [ 80 120 ];
        # "editor.fontSize" = 20;
        "editor.lineNumbers" = "interval";
        "editor.cursorBlinking" = "solid";
        # "editor.fontFamily" = "Fira Code";
        # "editor.fontLigatures" = true;
        # "editor.fontWeight" = "400";
        # "editor.formatOnSave" = true;
        # "editor.formatOnPaste" = true;
        "breadcrumbs.enabled" = true;
        # git
        "git.confirmSync" = false;
        "git.autofetch" = false;
        "magit.code-path" = "codium";
        "nix.enableLanguageServer" = true;
        "nix.serverPath" = "nil";
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
      ];
    };

    # git
    programs.git = {
      enable = true;
      userName = "DavHau";
      userEmail = "hsngrmpf+github@gmail.com";
      difftastic.enable = true;
      extraConfig = {
        # pack.compression = 0;
        # core.editor = "codium";
        init.defaultBranch = "main";
        rebase.autoStash = true;
      };
      aliases = {
        cl = "clone";
        gh-cl = "gh-clone";
        cr = "cr-fix";
        p = "push";
        pl = "pull";
        f = "fetch";
        fa = "fetch --all";
        a = "add";
        ap = "add -p";
        d = "diff";
        dl = "diff HEAD~ HEAD";
        ds = "diff --staged";
        l = "log --show-signature";
        l1 = "log -1";
        lp = "log -p";
        c = "commit";
        ca = "commit --amend";
        co = "checkout";
        cb = "checkout -b";
        cm = "checkout origin/master";
        de = "checkout --detach";
        fco = "fetch-checkout";
        br = "branch";
        s = "status";
        re = "reset --hard";
        r = "rebase";
        rc = "rebase --continue";
        ri = "rebase -i";
        m = "merge";
        t = "tag";
        su = "submodule update --init --recursive";
        bi = "bisect";
      };
    };
  };
}
