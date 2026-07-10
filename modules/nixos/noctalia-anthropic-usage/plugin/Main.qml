// Anthropic Fable Usage — plugin "service" instance.
//
// Reads the state file the anthropic-usage-poll user timer publishes
// (~/.local/state/anthropic-usage.json) and exposes it to the bar
// widget. One entry per Anthropic account:
//   { email, percent, resetsAt, stale }   percent ∈ 0..100 | null
// The file is watched so the bars move right after each poll.
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  // Injected by the plugin host (PluginService.createObject).
  property var pluginApi: null

  // Live list of accounts. Empty until the poller's first run.
  property var accounts: []

  readonly property string statePath: {
    const stateHome = Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state");
    return stateHome + "/anthropic-usage.json";
  }

  function _apply(raw) {
    try {
      const data = JSON.parse(raw);
      root.accounts = Array.isArray(data.accounts) ? data.accounts : [];
    } catch (e) {
      // Partial/atomic-rewrite read: keep the previous values rather
      // than blanking the bars on a transient parse failure.
    }
  }

  FileView {
    id: stateView
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: root._apply(text())
    onFileChanged: reload()
    onLoadFailed: {
      // No state yet (poller has not run): show nothing.
      root.accounts = [];
    }
  }

  Component.onCompleted: stateView.reload()
}
