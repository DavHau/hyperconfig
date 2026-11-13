# Host-local niri layout tweaks layered on top of the spaces base config.
#
# The spaces flake owns /etc/niri/config.kdl (the upstream default, which
# already contains a `layout {}` section); host-local additions go into the
# /etc/niri/config-laptop.kdl wrapper (created by ./niri-monitor-binds.nix,
# which also repoints NIRI_CONFIG at it). niri forbids duplicate sections only
# *within* one file -- across `include`d files sections are merged field by
# field (niri-config/src/lib.rs ConfigPart::decode_children), so this
# wrapper-level `layout {}` overlays the base one instead of clashing with it.
{
  environment.etc."niri/config-laptop.kdl".text = ''
    layout {
        // A lone column on an otherwise empty workspace opens centered
        // instead of squashed to the left edge. Only applies while it is
        // the single column; normal left-aligned scrolling resumes once a
        // second column appears.
        always-center-single-column
    }

    // Overview (Mod+O / noctalia's workspace button) zoomed further out:
    // 0.3 shows about 5 workspace rows instead of the default 0.5's ~3.
    overview {
        zoom 0.3
    }
  '';
}
