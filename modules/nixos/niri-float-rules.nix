# Floating window rules layered on top of the spaces base niri config.
#
# The spaces flake owns /etc/niri/config.kdl; host-local additions go into the
# /etc/niri/config-laptop.kdl wrapper (created by ./niri-monitor-binds.nix,
# which also repoints NIRI_CONFIG at it). environment.etc text is `lines`, so
# this fragment merges into that wrapper alongside the binds. niri watches
# included files, so a nixos-rebuild live-reloads the rules without a relogin.
{
  environment.etc."niri/config-laptop.kdl".text = ''
    // ssh-tpm-agent confirm dialog (yad, see ./ssh-tpm-agent.nix): a proper
    // floating popup instead of a tiled half-screen window. Match both ways:
    // the app-id covers yad regardless of dialog title, the title covers a
    // future non-yad dialog keeping the same name.
    window-rule {
        match app-id="^yad$"
        match title="^ssh-tpm-agent$"
        open-floating true
    }
  '';
}
