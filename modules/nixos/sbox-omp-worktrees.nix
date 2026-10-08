/*
  omp task-isolation worktrees inside sbox live on the projects' filesystem.

  omp (afk) snapshots the repo for every isolated subagent with per-file
  FICLONE clones into <omp dir>/wt. Inside sbox that path is in the session
  $HOME, i.e. on the sbox-state dataset (zroot/root/nobackup/sbox-state on
  amy), while the repos sit on zroot/root. FICLONE never crosses datasets
  (EXDEV), so every snapshot degraded to a full byte copy: ~21 GB per
  subagent in nmm, 850 GB in total on 2026-10-08.

  sbox scratch paths keep their per-session backing dir under
  ~/.local/share/sbox/scratch (zroot/root, same dataset as ~/synced and
  ~/projects), so the clones share blocks with the repo again. Lifetime is
  the sbox session's: removed with the session state (sbox-gc, launch
  prune). Per session, not shared: omp derives worktree dir names from repo
  + agent id and wipes that dir before reuse, so two sessions sharing one
  wt dir would delete each other's live worktrees.

  task.isolation.requireCow (set in ~/.omp/profiles/afk/agent/config.yml)
  turns any regression of this into a loud spawn failure instead of
  silent full copies.
*/
{
  programs.sbox.sessionState.scratch = [
    "$HOME/.omp/wt"
    "$HOME/.omp/profiles/afk/wt"
    "$HOME/.omp/profiles/oml/wt"
  ];
}
