{ pkgs, ... }:
let
  reviewPrompt = ''
    You're doing a final code-quality pass on the current changes before I
    submit them upstream. Channel the sensibilities of Kent Beck (Tidy First?,
    TDD), Martin Fowler (Refactoring), John Ousterhout (A Philosophy of
    Software Design), Robert C. Martin (Clean Code), Michael Feathers (Working
    Effectively with Legacy Code), and Hunt & Thomas (The Pragmatic
    Programmer) — but apply taste, not dogma. Their advice conflicts in
    places; pick what actually serves this change.

    Read the full diff before touching anything. Then evaluate it through
    these lenses:

    DOES IT EARN ITS PLACE?
    - Is every line pulling its weight? Delete what isn't.
    - Any abstraction that isn't paying rent? Inline it. (Premature abstraction
      is worse than duplication.)
    - Any duplication that's really conceptual unity in disguise? Unify it.
      Any "duplication" that's incidental similarity? Leave it alone.

    WILL THE NEXT READER GET IT IN 30 SECONDS?
    - Names should reveal intent. If a reader has to jump elsewhere to
      understand a name, rename it.
    - Prefer deep modules with simple interfaces over shallow ones with wide
      interfaces (Ousterhout).
    - Strip comments that restate the code. Keep or add comments that explain
      WHY — non-obvious tradeoffs, historical context, gotchas, links to
      issues.

    IS IT CORRECT AT THE BOUNDARIES?
    - Every error path: handled deliberately, or propagated deliberately?
      Never accidentally.
    - Every input: what happens at empty, null, zero, negative, max, malformed,
      concurrent, partial-failure?
    - Every assumption: documented, asserted, or enforced by types.

    DOES IT FIT THE CODEBASE?
    - Match existing style, naming, file layout, error-handling patterns.
      A patch that looks like it was always there gets merged.
    - New dependencies must be justified. Prefer the stdlib.

    TESTS
    - One behavior per test; name it for what it verifies, not what it calls.
    - Cover unhappy paths, not just the happy one.
    - No tests that only exercise the mock.

    COMMIT HYGIENE
    - Each commit: one coherent atomic change.
    - Each message: explains WHY, not just what. Reference the issue.
    - Squash "fix typo" / "address review" noise.

    When you're done, give me:
    1. What you changed and why (briefly).
    2. What you considered changing but didn't, with reasoning.
    3. Anything you're unsure about that I should eyeball myself.

    The bar: would a senior maintainer of this project say "nice patch" rather
    than "requesting changes"? Don't golf the code. Don't over-engineer.
    Boring and obvious beats clever.
  '';
  promptFile = pkgs.writeText "omr-prompt.md" reviewPrompt;
  omr = pkgs.writeShellApplication {
    name = "omr";
    runtimeInputs = [ ];
    text = ''
      exec omp "@${promptFile}" "$@"
    '';
  };
in
{
  environment.systemPackages = [ omr ];
}
