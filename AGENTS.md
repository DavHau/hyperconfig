# hyperconfig

Dave's clan-based NixOS fleet. Before exploring, read
`skills/hyperconfig-map/SKILL.md` (where things live, `nix eval`
one-liners, recipes, and the Mechanisms index: which module owns each
concern; grep its `references/map-*.md` for machines, modules, options
and generators). Before adding a module, option, generator, id or port,
read `CONVENTIONS.md` (extend vs create, naming, registries);
`checks.x86_64-linux.hygiene` enforces it. After adding, moving or
renaming a module, run `nix run .#repo-map` and commit the regenerated
maps.
