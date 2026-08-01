#!/usr/bin/env python3
"""Confirmation dialog for the patched ssh-tpm-agent (see ssh-tpm-agent.nix).

Reads the peer's process ancestry from SSH_TPM_CHOICES (one
"pid<TAB>name<TAB>cwd" line per process, requester first; cwd may be empty for
sandboxed peers), lets the user pick WHICH process to trust and for how long,
and prints the agent's grant protocol on stdout:

    temporary <pid>   trust for SSH_TPM_CONFIRM_TTL
    session <pid>     trust until the process exits / the agent restarts
    deny

This replaces the previous `yad --list --radiolist` invocation. yad gives no
control over two things this dialog needs:

  * Size. yad sizes the list to a fixed default, so four ancestry rows landed
    in a scrollbox. Here the window grows with the row count (capped at 80% of
    the monitor's work area), so the whole ancestry is visible at once.

  * Keyboard-inaccessible buttons. This dialog appears unannounced on top of
    whatever the user is typing into; a stray Return must never approve a
    signature. The action buttons are can_focus=False and there is no default
    widget, and Return/space/Tab are swallowed at the window level. Escape is
    the one accepted key because it denies (the safe direction).
"""

import os
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

# Grant kinds, mapped to the stdout protocol above.
TEMPORARY, SESSION, DENY = "temporary", "session", "deny"

# Measured against the GTK default theme: a row renders ~28px, the treeview
# header ~25px, and the surrounding chrome (heading, hint, button row, margins)
# ~155px. Rounded up so the list never needs to scroll.
ROW_HEIGHT = 30
CHROME_HEIGHT = 165
MIN_LIST_HEIGHT = 2 * ROW_HEIGHT
DEFAULT_WIDTH = 1000


def parse_choices(raw):
    """SSH_TPM_CHOICES -> [(pid, name, cwd)], requester first."""
    choices = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        pid = parts[0].strip()
        if not pid:
            continue
        name = parts[1] if len(parts) > 1 else ""
        cwd = parts[2] if len(parts) > 2 else ""
        choices.append((pid, name, cwd))
    return choices


class ConfirmDialog(Gtk.Window):
    def __init__(self, prompt, choices, ttl):
        super().__init__(title="ssh-tpm-agent")
        self.result = DENY
        self.choices = choices

        self.set_position(Gtk.WindowPosition.CENTER_ALWAYS)
        self.set_type_hint(Gdk.WindowTypeHint.DIALOG)
        self.set_modal(True)
        self.set_keep_above(True)
        self.connect("destroy", lambda *_: Gtk.main_quit())
        self.connect("key-press-event", self._on_key_press)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.set_margin_top(16)
        box.set_margin_bottom(16)
        box.set_margin_start(16)
        box.set_margin_end(16)
        self.add(box)

        heading = Gtk.Label(xalign=0.0)
        heading.set_markup("<b>%s</b>" % GLib.markup_escape_text(prompt))
        heading.set_line_wrap(True)
        heading.set_selectable(False)
        box.pack_start(heading, False, False, 0)

        hint = Gtk.Label(xalign=0.0)
        hint.set_markup(
            "<small>Pick the process to trust — the grant covers it and all of "
            "its children. Buttons are mouse-only; Esc denies.</small>"
        )
        hint.set_line_wrap(True)
        box.pack_start(hint, False, False, 0)

        box.pack_start(self._build_list(), True, True, 0)
        box.pack_start(self._build_buttons(ttl), False, False, 0)

        self.set_default_size(DEFAULT_WIDTH, self._preferred_height())

    def _build_list(self):
        # pid, name, cwd — selection is the trust target, so no radio column.
        self.store = Gtk.ListStore(str, str, str)
        for pid, name, cwd in self.choices:
            self.store.append([pid, name, cwd or "—"])

        self.view = Gtk.TreeView(model=self.store, headers_visible=True)
        self.view.set_activate_on_single_click(False)
        # Only the Directory column ellipsizes: an ellipsizing cell reports a
        # near-zero natural width, which is what squashed PID down to "42…".
        for i, (title, expand, ellipsize) in enumerate(
            [("PID", False, False), ("Process", False, False), ("Directory", True, True)]
        ):
            cell = Gtk.CellRendererText(ypad=4, xpad=6)
            cell.set_property("family", "monospace")
            if ellipsize:
                cell.set_property("ellipsize", 3)  # Pango.EllipsizeMode.END
            column = Gtk.TreeViewColumn(title, cell, text=i)
            column.set_resizable(True)
            column.set_expand(expand)
            self.view.append_column(column)

        selection = self.view.get_selection()
        selection.set_mode(Gtk.SelectionMode.BROWSE)
        if len(self.store):
            selection.select_iter(self.store.get_iter_first())

        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroller.set_shadow_type(Gtk.ShadowType.IN)
        scroller.set_min_content_height(
            max(MIN_LIST_HEIGHT, ROW_HEIGHT * len(self.choices))
        )
        scroller.add(self.view)
        return scroller

    def _build_buttons(self, ttl):
        bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        bar.set_halign(Gtk.Align.END)
        for label, kind, style in [
            ("Deny", DENY, "destructive-action"),
            ("Trust %s" % ttl, TEMPORARY, "suggested-action"),
            ("Trust forever", SESSION, None),
        ]:
            button = Gtk.Button(label=label)
            # The whole point: no keyboard route to an approval.
            button.set_can_focus(False)
            button.set_can_default(False)
            button.set_size_request(150, 40)
            if style:
                button.get_style_context().add_class(style)
            button.connect("clicked", self._on_click, kind)
            bar.pack_start(button, False, False, 0)
        return bar

    def _preferred_height(self):
        wanted = CHROME_HEIGHT + max(MIN_LIST_HEIGHT, ROW_HEIGHT * len(self.choices))
        display = Gdk.Display.get_default()
        if display is None:
            return wanted
        monitor = display.get_primary_monitor() or display.get_monitor(0)
        if monitor is None:
            return wanted
        return min(wanted, int(monitor.get_workarea().height * 0.8))

    def _selected_pid(self):
        model, treeiter = self.view.get_selection().get_selected()
        if treeiter is None:
            return None
        return model[treeiter][0]

    def _on_click(self, _button, kind):
        pid = self._selected_pid()
        self.result = DENY if (kind != DENY and pid is None) else kind
        self.pid = pid
        Gtk.main_quit()

    def _on_key_press(self, _widget, event):
        """Escape denies; every other key is swallowed.

        Arrow keys still move the list selection (handled before this returns
        True only for the activation keys), but nothing on the keyboard can
        commit a grant.
        """
        keyval = event.keyval
        if keyval == Gdk.KEY_Escape:
            self.result = DENY
            Gtk.main_quit()
            return True
        if keyval in (
            Gdk.KEY_Return,
            Gdk.KEY_KP_Enter,
            Gdk.KEY_ISO_Enter,
            Gdk.KEY_space,
            Gdk.KEY_KP_Space,
            Gdk.KEY_Tab,
            Gdk.KEY_ISO_Left_Tab,
        ):
            return True
        return False


def main():
    prompt = sys.argv[1] if len(sys.argv) > 1 else "Authorise SSH key use?"
    ttl = os.environ.get("SSH_TPM_CONFIRM_TTL", "15m")
    choices = parse_choices(os.environ.get("SSH_TPM_CHOICES", ""))
    # Pins the wayland app-id / X11 WM_CLASS the niri float rule matches on
    # (see niri-float-rules.nix); otherwise it follows argv[0].
    GLib.set_prgname("ssh-tpm-confirm-dialog")
    if not choices:
        print(DENY)
        return 0

    dialog = ConfirmDialog(prompt, choices, ttl)
    dialog.pid = None
    dialog.show_all()
    dialog.present()
    Gtk.main()

    if dialog.result == DENY or dialog.pid is None:
        print(DENY)
    else:
        print("%s %s" % (dialog.result, dialog.pid))
    return 0


if __name__ == "__main__":
    sys.exit(main())
