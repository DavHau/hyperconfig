# Names of the per-agent clan vars generators ../modules/clan.nix declares,
# for a consumer that must name them on another machine (a TeamClaude
# gateway declaring each agent's key as its client, a host reading an
# agent's public ssh key with clanLib.getPublicValue). Renaming one orphans
# the stored secret.
{
  # `key` (the agent's ssh private key) and `key.pub`.
  agentSshGenerator = agent: "hermes-agent-ssh-${agent}";
  # `key`: the agent's TeamClaude gateway client key.
  teamclaudeGenerator = agent: "teamclaude-hermes-${agent}";
  # Shared: `key` and `key.pub` of the desktop app's ssh key.
  desktopSshGenerator = "hermes-desktop-ssh";
}
