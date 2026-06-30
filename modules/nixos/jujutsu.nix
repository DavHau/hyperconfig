{ pkgs, lib, inputs, ... }:
let
  jj = (inputs.wrappers.wrapperModules.jujutsu.apply {
    inherit pkgs;
    settings = {
      user.name = "DavHau";
      user.email = "need-more-ram@DavHau.com";

      # Emit git-format diffs so delta can render them syntax-highlighted
      # side-by-side when it acts as the pager.
      ui.diff-formatter = ":git";

      ui.default-command = ["log" "-r" "all()"];

      # delta as pager. `--paging=auto` makes delta only spawn its internal
      # less when the output exceeds the terminal, so short `jj log` output
      # stays in the terminal instead of dropping into a pager.
      ui.pager = [
        "${pkgs.delta}/bin/delta"
        "--side-by-side"
        "--line-numbers"
        "--navigate"
        "--paging=auto"
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
