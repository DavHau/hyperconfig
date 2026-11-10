---
name: forge-prs
description: >
  Use when opening, commenting on, reviewing or merging a pull request on
  git.geninf.io or git.clan.lol from this space, or when checking which
  forge account and repositories the space has. `tea` is set up with the
  bot accounts' API tokens; git pushes go over ssh.
---

# Pull requests on the forges (tea)

Both forges are Gitea. `tea` (Gitea's CLI) is on PATH with one login per
forge this space has, named after the host (`git.geninf.io`,
`git.clan.lol`), each with its bot account's API token. Logins are
declared by the system; do not run `tea login add` (it would not persist).

    tea logins list          # forges, URLs, the bot user of each
    space-forge-check        # token valid? which repos can the bot push to?

## Which forge and repo

Inside a checkout tea picks the login whose host matches the git remote
(`gitea@git.geninf.io:owner/repo.git`) and the repo from it. Elsewhere,
or to be explicit: `--login git.clan.lol --repo owner/repo`.

## Non-interactive use (agents)

Always pass flags/arguments: tea goes interactive (a TUI) when a command
gets none (`tea pr create` without flags, `tea pr merge` without an
index, `tea pr review`). Use `-o json` where offered for parseable
output. `tea api` exits 0 even on HTTP errors: check the JSON body.

## Open a PR

Push a branch over ssh, then create the PR from it:

    jj git push --named my-topic=@-          # or: git push origin HEAD:my-topic
    tea pr create --head my-topic --base main \
      --title "component: what changes" --description-file pr.md

Alternative without a branch on the forge (AGit flow, Gitea-native):

    git push origin HEAD:refs/for/main -o topic=my-topic \
      -o title="component: what changes" -o description="why"

Pushing again to the same `refs/for/main` with the same topic updates
that PR.

## Look, comment, review

    tea pr ls --state open -o json
    tea pr 12 --comments                    # details of PR #12
    tea comment 12 "text"                    # comment on PR/issue #12
    tea pr approve 12 "LGTM: tested X"
    tea pr reject 12 "needs Y"               # request changes
    tea pr review-comments 12                # inline review comments

## Merge

    tea pr merge 12 --style squash --title "component: what changes"
    # styles: merge, rebase, squash, rebase-merge

Merge only when asked to (or the task says so), never your own PR
unreviewed unless told to. After a merge: `tea pr clean 12` removes the
merged branch.

## Anything else

`tea api` calls the REST API with the login's token:

    tea api --login git.geninf.io /user
    tea api --login git.geninf.io -X POST /repos/OWNER/REPO/pulls/12/requested_reviewers \
      -d '{"reviewers":["someone"]}'
