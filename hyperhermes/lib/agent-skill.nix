# Copied from spaces (git+https://git.geninf.io/spaces/spaces-os, rev
# 6d744780ad0a850969a89cf045a11871d489ec19, lib/agent-skill.nix) so this flake
# does not depend on spaces. The consumers named below are spaces' own.
#
# Package one Agent Skill in the layout every harness reads:
#
#   $out/share/skills/<name>/SKILL.md
#
# That path is the interchange format between skill producers and agent
# harnesses. github.com/Mic92/mics-skills publishes the same layout, so a
# spaces skill and a third-party skill package are interchangeable.
#
# Two consumers in this repo read it. modules/home/agent-skills.nix links each
# skill into the skill root of every harness the user runs.
# modules/nixos/hermes/guest.nix hands the joined root to the hermes agent as
# skills.external_dirs.
#
# `packages` holds the CLIs the SKILL.md tells the agent to run. They travel
# with the skill, so a harness cannot offer a skill whose tools it never
# installs. The two lists used to live apart, and osm-cli and caldav-cli both
# shipped as a skill with no CLI. checks/hermes-skill-clis-on-path caught
# that; carrying the CLIs here stops it happening again.
#
# `passthru.skillName` lets a consumer resolve the skill directory without
# reading the store path, which would force the derivation at eval time.
pkgs:
{
  name,
  src,
  packages ? [ ],
  meta ? { },
}:
pkgs.runCommand "agent-skill-${name}"
  {
    inherit src;
    passthru = {
      skillName = name;
      skillPackages = packages;
    };
    meta = {
      description = "Agent skill: ${name}";
    }
    // meta;
  }
  ''
    if [ ! -f "$src/SKILL.md" ]; then
      echo "agent-skill ${name}: $src/SKILL.md does not exist" >&2
      exit 1
    fi

    # The frontmatter name is what a harness shows the model. The directory
    # name is what it indexes. A difference splits the two identities: the
    # model is told one name and can ask for a skill that no root holds.
    declared=$(sed -n '2,/^---$/{s/^name:[[:space:]]*//p}' "$src/SKILL.md" | head -1)
    if [ "$declared" != "${name}" ]; then
      echo "agent-skill ${name}: SKILL.md declares name '$declared'" >&2
      exit 1
    fi

    mkdir -p "$out/share/skills"
    cp -r "$src" "$out/share/skills/${name}"
  ''
