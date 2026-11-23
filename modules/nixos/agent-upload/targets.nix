# Upload paths into som's hermes agents' workspaces (./default.nix), one
# entry per agent: the machine that sends (`from`, with its own key, clan
# var agent-upload-<agent>-ssh) and the one the agent lives on (`to`).
# Files land in /home/<agent>/hermes/workspace/uploads/<source dir name>/.
{
  wolfgang = {
    from = "amy";
    to = "som";
  };
}
