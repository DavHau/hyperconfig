{ pkgs, lib, ... }:
let
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

  gitconfig = pkgs.writeText "gitconfig" (lib.generators.toGitINI settings);
  # Wrap ONLY bin/git. pkgs.git ships bin/git-upload-pack, git-receive-pack
  # and git-upload-archive as RELATIVE symlinks to bin/git (the real binary
  # dispatches on argv0). Any wrapper that replaces bin/git inherits those
  # links, so sshd's `git-upload-pack '<repo>'` lands in the wrapper, which
  # ignores argv0 and runs `git '<repo>'`: git-over-ssh to every host failed
  # with "'<repo>' is not a git command" (the previous lassulus/wrappers
  # package had exactly this shape). Here the helpers are re-pointed at the
  # real binaries; only the interactive entry point carries the config.
  git = pkgs.symlinkJoin {
    name = "git-${pkgs.git.version}-wrapped";
    paths = [ pkgs.git ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      for f in "$out"/bin/git-*; do
        if [ -L "$f" ] && [ "$(readlink "$f")" = git ]; then
          ln -sfn "${pkgs.git}/bin/$(basename "$f")" "$f"
        fi
      done
      rm "$out/bin/git"
      makeWrapper "${pkgs.git}/bin/git" "$out/bin/git" \
        --set GIT_CONFIG_GLOBAL "${gitconfig}"
    '';
    inherit (pkgs.git) meta;
  };
in
{
  environment.systemPackages = [
    (lib.hiPrio git)
    pkgs.difftastic
    pkgs.delta
  ];
}
