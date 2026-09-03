{ pkgs, inputs, ... }:
# jj workspace support for herdr via the community herdr-jj plugin
# (OliverGilan/herdr-jj, MIT): create/open/remove/inspect jj workspaces as
# herdr spaces, jj change + status tokens for the spaces sidebar. Upstream
# herdr has no jj support (herdrdev/herdr discussion #480); this plugin is
# the community implementation for it.
#
# herdr plugins are normally `herdr plugin install <gh>` at runtime (cargo
# build on the user's machine). Instead the plugin binary is built by nix and
# exposed as a plugin directory (manifest + ./target/release/herdr-jj layout
# the manifest's relative commands expect); the wrapper below registers it
# idempotently with `herdr plugin link` on every launch — offline the link
# writes the plugin registry directly, with a running server it updates live.
let
  sys = pkgs.stdenv.hostPlatform.system;
  herdr = inputs.llm-agents.packages.${sys}.herdr;

  herdr-jj = pkgs.rustPlatform.buildRustPackage {
    pname = "herdr-jj";
    version = "0.1.0-unstable-2026-09-03";
    src = pkgs.fetchFromGitHub {
      owner = "OliverGilan";
      repo = "herdr-jj";
      rev = "4fe4efacf70bf5986c1e2ed49f11772d6358bc81";
      hash = "sha256-kjbLFtCd3vMIA0wwpgOXo7yps8QJDIlvgTaHoPwZgKU=";
    };
    cargoHash = "sha256-0Yp58X/ldgJdA/CpTzH8CGk0HnvE4toPRMSwD4VJ+20=";
    # Tests build real temp jj repos and a fake herdr executable; they need
    # jj on PATH and PTY access — not sandbox material (upstream herdr's
    # package sets doCheck = false for the same reason).
    doCheck = false;
  };

  # Plugin directory in the layout herdr-plugin.toml expects. The [[build]]
  # step (cargo build --release) is stripped: the binary is prebuilt above
  # and the store checkout is read-only anyway.
  herdr-jj-plugin = pkgs.runCommand "herdr-jj-plugin" { } ''
    mkdir -p $out/target/release
    ln -s ${herdr-jj}/bin/herdr-jj $out/target/release/herdr-jj
    sed '/^\[\[build\]\]/,/^$/d' ${herdr-jj.src}/herdr-plugin.toml > $out/herdr-plugin.toml
  '';

  # Seeded once: the plugin's actions only become reachable through the
  # keybindings the herdr-jj README tells you to add, and the sidebar rows
  # need its $jj_change/$jj_status tokens. config.toml stays user-owned —
  # never overwritten if it exists.
  seedConfig = pkgs.writeText "herdr-config-seed.toml" ''
    [[keys.command]]
    key = "prefix+shift+a"
    type = "plugin_action"
    command = "olivergilan.herdr-jj.create"
    description = "new JJ workspace"

    [[keys.command]]
    key = "prefix+a"
    type = "plugin_action"
    command = "olivergilan.herdr-jj.open"
    description = "open JJ workspace"

    [[keys.command]]
    key = "prefix+d"
    type = "plugin_action"
    command = "olivergilan.herdr-jj.remove"
    description = "remove JJ workspace"

    [ui.sidebar.spaces]
    rows = [
      ["state_icon", "workspace"],
      ["$jj_change", "$jj_status"],
    ]
  '';
in
{
  environment.systemPackages = [
    (inputs.wrappers.lib.wrapPackage {
      inherit pkgs;
      package = herdr;
      preHook = ''
        if [ ! -e "$HOME/.config/herdr/config.toml" ]; then
          mkdir -p "$HOME/.config/herdr"
          cp ${seedConfig} "$HOME/.config/herdr/config.toml"
          chmod u+w "$HOME/.config/herdr/config.toml"
        fi
        # Idempotent: link replaces any previous registry entry for the same
        # plugin id, so a store-path change after a rebuild re-registers.
        ${herdr}/bin/herdr plugin link ${herdr-jj-plugin} >/dev/null || true
      '';
    })
  ];
}
