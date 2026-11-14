# nixpkgs-bump-searxng (./searxng.sh), for ../nixpkgs-bump.nix (the
# guest's PATH). `bumpNix` is the run's nix wrapper (its builds keep the
# bump's max-jobs and cores). The scratch instance runs on the host
# (../../searxng-canary/candidate.nix), not here; the review's diff is
# ./searxng-diff.nix.
{
  pkgs,
  bumpNix,
  # ./guard-test.nix passes a stub (GitHub's API from files)
  curl ? pkgs.curl,
  # the reviewer's hermes python env (./searxng-diff.nix says why)
  hermesVenv,
  logDir ? "/home/infra/nixpkgs-bump",
  socket ? "/run/searxng-candidate/socket",
  # the decision registry's inbox (infra-space's `decision`; its agreed
  # path for jobs)
  decisionInbox ? "/var/lib/infra-space/decisions/inbox.jsonl",
  minAgeHours ? 72,
  maxDiffLines ? 3000,
  # the counted code diff's bytes (long lines slip under the line cap)
  maxDiffBytes ? 300000,
  # the step-wise pick's diffs per night, when the aged tip holds
  # (each a prefetch and a diff; GitHub's unauthenticated rate limit is
  # 60 calls an hour)
  maxSteps ? 20,
}:
pkgs.writeShellApplication {
  name = "nixpkgs-bump-searxng";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.findutils
    curl
    pkgs.gawk
    pkgs.git
    pkgs.gnugrep
    pkgs.jq
    pkgs.jujutsu
    pkgs.socat
    bumpNix
    (import ./searxng-diff.nix { inherit pkgs hermesVenv; })
  ];
  text =
    builtins.replaceStrings
      [ "@logDir@" "@socket@" "@decisionInbox@" "@minAgeHours@" "@maxDiffLines@" "@maxDiffBytes@" "@maxSteps@" "@tips@" ]
      [
        logDir
        socket
        decisionInbox
        (toString minAgeHours)
        (toString maxDiffLines)
        (toString maxDiffBytes)
        (toString maxSteps)
        # master's tips as we first saw them: the age gate's record (the
        # guard reads it too, ./guard.nix)
        "${logDir}/searxng-tips.jsonl"
      ]
      (builtins.readFile ./searxng.sh);
}
