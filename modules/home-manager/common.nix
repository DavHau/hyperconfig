{ pkgs, lib, ... }: {
  imports = [
    ./vscode.nix
  ];

  # services
  services.dunst.enable = true;
  services.udiskie.enable = true;
  systemd.user.targets.tray = {
    Unit = {
      Description = "Home Manager System Tray";
      Requires = [ "graphical-session-pre.target" ];
    };
  };

  programs.fish.enable = true;

  programs.alacritty.enable = true;
  programs.alacritty.settings = {
    font.size = 14;
    font.normal.family = "FiraCode Nerd Font";
  };
  programs.alacritty.package = pkgs.alacritty;

  programs.zoxide.enable = true;

  # git
  programs.difftastic.enable = true;
  programs.difftastic.git.enable = true;
  programs.git = {
    enable = true;
    settings = {
      user.name = "DavHau";
      user.email = "hsngrmpf+github@gmail.com";
      init.defaultBranch = "main";
      pull.rebase = true;
      rebase.autoStash = true;
      git.commit.autoWrapCommitMessage = false;
      push.autoSetupRemote = true;
      alias = {
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
