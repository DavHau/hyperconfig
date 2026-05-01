{ pkgs, lib, inputs, ... }:
let
  jj = (inputs.wrappers.wrapperModules.jujutsu.apply {
    inherit pkgs;
    settings = {
      user.name = "DavHau";
      user.email = "need-more-ram@DavHau.com";

      # Default diff/show output: emit unified `git`-format and let delta
      # render syntax-highlighted side-by-side view (vscode-like).
      ui.diff-formatter = ":git";
      ui.pager = [
        "${pkgs.delta}/bin/delta"
        "--side-by-side"
        "--line-numbers"
        "--navigate"
        "--paging=always"
      ];

      # Opt-in semantic/AST diff via `jj diff --tool difft`.
      merge-tools.difft = {
        program = "${pkgs.difftastic}/bin/difft";
        diff-args = [ "--color=always" "$left" "$right" ];
        diff-invocation-mode = "file-by-file";
      };
    };
  }).wrapper;
in {
  environment.systemPackages = [
    (lib.hiPrio jj)
    pkgs.delta
  ];
}
