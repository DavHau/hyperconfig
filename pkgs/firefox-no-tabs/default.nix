# firefox-no-tabs: nixpkgs Firefox whose browser/omni.ja is patched so
# that every new tab (Ctrl+T, Ctrl/middle-click, target=_blank,
# window.open, external links, extensions' tabs.create) opens a new window
# instead, and the tab bar is collapsed. Replaces the "No Tabs" extension.
#
# Ported from Christian Friedow's dotfiles (MIT),
# https://github.com/friedow/dotfiles/commit/97915b129657390c70074610cc1ac6c4a19b1795
# (packages/firefox/). Only the no-tabs part; his back/forward-button
# hiding is dropped. check.py runs in the build and fails it when any way
# of opening a tab still produces one.
#
# Returns the patched *unwrapped* Firefox; wrap it at the call site with
# `pkgs.wrapFirefox (pkgs.callPackage ./pkgs/firefox-no-tabs { }) { }`.
# (callPackage's own .override would shadow wrapFirefox's, and
# home-manager could then not add policies.)
{
  lib,
  firefox-unwrapped,
  runCommand,
  unzip,
  zip,
  python3,
  geckodriver,
}:
let
  unwrapped = firefox-unwrapped;

  # Firefox's UI is JS/CSS packed into browser/omni.ja. Instead of compiling
  # Firefox we patch that archive, so the binary stays the cached build
  # from nixpkgs.
  #
  # Every edit replaces a single anchor line with --replace-fail. The
  # anchors stayed identical from Firefox 146 to 159 (friedow); if an
  # update removes one, the build fails here and only that anchor needs
  # fixing.
  edits = [
    {
      # Ctrl+T, middle-click, Ctrl+click, context menu, about: pages, ...
      file = "modules/URILoadingHelper.sys.mjs";
      anchor = "openLinkIn(window, url, where, params) {";
      replacement = ''
        openLinkIn(window, url, where, params) {
            // firefox-no-tabs: every new tab becomes a new window
            if (where == "tab" || where == "tabshifted") {
              where = "window";
              if (
                params &&
                !params.forceNonPrivate &&
                window &&
                ChromeUtils.importESModule(
                  "resource://gre/modules/PrivateBrowsingUtils.sys.mjs"
                ).PrivateBrowsingUtils.isWindowPrivate(window)
              ) {
                params = Object.assign({}, params, { private: true });
              }
            }
      '';
    }
    {
      # Links from other applications, --new-tab, Nimbus overrides
      file = "modules/BrowserDOMWindow.sys.mjs";
      anchor = "switch (aWhere) {";
      replacement = ''
        // firefox-no-tabs: never open a tab, always a window
            if (
              aWhere == Ci.nsIBrowserDOMWindow.OPEN_NEWTAB ||
              aWhere == Ci.nsIBrowserDOMWindow.OPEN_NEWTAB_BACKGROUND ||
              aWhere == Ci.nsIBrowserDOMWindow.OPEN_NEWTAB_FOREGROUND ||
              aWhere == Ci.nsIBrowserDOMWindow.OPEN_NEWTAB_AFTER_CURRENT
            ) {
              aWhere = Ci.nsIBrowserDOMWindow.OPEN_NEWWINDOW;
            }
            switch (aWhere) {'';
    }
    {
      # target=_blank and window.open are routed by C++ using this pref
      file = "defaults/preferences/firefox.js";
      anchor = ''pref("browser.link.open_newwindow", 3);'';
      replacement = ''pref("browser.link.open_newwindow", 2);'';
    }
    {
      # browser.tabs.create from extensions (e.g. Vimium): open a fresh
      # window and create the tab there instead of next to the others.
      file = "chrome/browser/content/browser/parent/ext-tabs.js";
      anchor = "let { gBrowserInit } = window;";
      replacement = ''
        // firefox-no-tabs: extension-created tabs get their own window
                    {
                      const { BrowserWindowTracker } = ChromeUtils.importESModule(
                        "resource:///modules/BrowserWindowTracker.sys.mjs"
                      );
                      const blank = Cc[
                        "@mozilla.org/supports-string;1"
                      ].createInstance(Ci.nsISupportsString);
                      blank.data = "about:blank";
                      window = BrowserWindowTracker.openWindow({
                        openerWindow: window,
                        private: PrivateBrowsingUtils.isWindowPrivate(window),
                        args: blank,
                      });
                      window.__firefoxNoTabsFresh = true;
                      createProperties.openerTabId = null;
                      createProperties.index = null;
                    }
                    let { gBrowserInit } = window;'';
    }
    {
      # ...and drop the about:blank tab the fresh window started with.
      file = "chrome/browser/content/browser/parent/ext-tabs.js";
      anchor = "let nativeTab = window.gBrowser.addTab(url, options);";
      replacement = ''
        let firefoxNoTabsInitialTab = window.__firefoxNoTabsFresh
                      ? window.gBrowser.tabs[0]
                      : null;
                    delete window.__firefoxNoTabsFresh;
                    let nativeTab = window.gBrowser.addTab(url, options);
                    if (firefoxNoTabsInitialTab) {
                      window.gBrowser.selectedTab = nativeTab;
                      window.gBrowser.removeTab(firefoxNoTabsInitialTab, {
                        animate: false,
                        skipPermitUnload: true,
                      });
                    }'';
    }
  ];

  applyEdit =
    edit:
    "substituteInPlace omni/${edit.file} --replace-fail ${lib.escapeShellArg edit.anchor} ${lib.escapeShellArg edit.replacement}";

in
runCommand unwrapped.name
      {
        inherit (unwrapped) version meta passthru;
        nativeBuildInputs = [
          unzip
          zip
          (python3.withPackages (p: [ p.selenium ]))
        ];
      }
      ''
        set -euo pipefail

        # Copy instead of symlinking: Firefox resolves its real install
        # location, so a symlink farm would load the unpatched omni.ja.
        cp -a ${unwrapped} $out
        chmod -R u+w $out

        # The launcher hardcodes its own store path. The derivation name is
        # identical, so the replacement has the same length.
        LC_ALL=C sed -i "s|${unwrapped}|$out|g" $out/bin/firefox
        if grep -rlF ${unwrapped} $out; then
          echo "firefox-no-tabs: stale reference to ${unwrapped}" >&2
          exit 1
        fi

        jar=$out/lib/firefox/browser/omni.ja
        # Firefox's optimized jar layout makes unzip complain (exit 1/2)
        # although it extracts everything, so verify by counting files.
        unzip -Z1 "$jar" > listing || [ $? -le 2 ]
        unzip -q "$jar" -d omni || [ $? -le 2 ]
        expected=$(grep -cv '/$' listing)
        actual=$(find omni -type f | wc -l)
        if [ "$expected" != "$actual" ]; then
          echo "firefox-no-tabs: extracted $actual of $expected files" >&2
          exit 1
        fi

        ${lib.concatMapStringsSep "\n" applyEdit edits}

        # Remove the tab bar. Keep the element: gBrowser needs the tab
        # strip inside it, and display:none breaks it.
        grep -qF '<toolbar id="TabsToolbar"' omni/chrome/browser/content/browser/browser.xhtml
        cat >> omni/chrome/browser/skin/classic/browser/browser.css <<'EOF'

        /* firefox-no-tabs */
        #TabsToolbar {
          visibility: collapse !important;
        }
        EOF

        rm "$jar"
        (cd omni && zip -qr9XD "$jar" .)

        # Behaviour check: drive the result headless and fail the build if
        # any way of opening a tab still produces one.
        HOME=$TMPDIR python3 ${./check.py} $out/bin/firefox ${lib.getExe geckodriver}
      ''
