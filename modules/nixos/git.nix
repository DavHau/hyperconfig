{ pkgs, lib, inputs, ... }:
let
  git = (inputs.wrappers.wrapperModules.git.apply {
    inherit pkgs;
    settings = {
      user.name = "DavHau";
      user.email = "need-more-ram@DavHau.com";
      init.defaultBranch = "main";
      pull.rebase = true;
      rebase.autoStash = true;
      commit.autoWrapCommitMessage = false;
      push.autoSetupRemote = true;
      core.pager = "${pkgs.delta}/bin/delta";
      interactive.diffFilter = "${pkgs.delta}/bin/delta --color-only";
      delta = {
        side-by-side = true;
        line-numbers = true;
        navigate = true;
        dark = true;
        syntax-theme = "Monokai Extended";
      };
      # Opt into semantic/AST diff:
      #   GIT_EXTERNAL_DIFF=difft git log -p --ext-diff
      diff.tool = "difftastic";
      difftool.difftastic.cmd = ''${pkgs.difftastic}/bin/difft "$LOCAL" "$REMOTE"'';
      difftool.prompt = false;
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
  }).wrapper;
in {
  environment.systemPackages = [
    (lib.hiPrio git)
    pkgs.difftastic
    pkgs.delta
  ];
}
