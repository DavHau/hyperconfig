{ ... }:
{
  # Deluge 2.2.0 GTK UI calls the deprecated Gtk.Menu.popup() for the
  # Files/Peers tab context menus. Those menus are standalone GtkMenus from
  # the builder (no attach widget), so on Wayland GDK cannot map them:
  #   "Window is a temporary window without parent"
  #   "gdk_wayland_window_handle_configure_popup: assertion 'impl->transient_for' failed"
  # Result: right-click in the Files tab shows nothing. Upstream develop is
  # still unfixed (same bug class as deluge tickets #3265/#3266/#3407).
  # Patch to the Wayland-capable popup_at_pointer().
  nixpkgs.overlays = [
    (final: prev: {
      deluge = prev.deluge.overridePythonAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace deluge/ui/gtk3/files_tab.py \
            --replace-fail \
              "self.file_menu.popup(None, None, None, None, event.button, event.time)" \
              "self.file_menu.popup_at_pointer(event)" \
            --replace-fail \
              "self.file_menu.popup(None, None, None, None, 3, event.time)" \
              "self.file_menu.popup_at_pointer(None)"
          substituteInPlace deluge/ui/gtk3/peers_tab.py \
            --replace-fail \
              "self.peer_menu.popup(None, None, None, None, event.button, event.time)" \
              "self.peer_menu.popup_at_pointer(event)"
        '';
      });
    })
  ];
}
