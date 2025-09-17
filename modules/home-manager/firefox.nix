{pkgs, ...}: {
  programs.firefox = {
    enable = true;

    /* package = pkgs.firefox-esr; */

    profiles.dave = {
      # extensions.packages = with pkgs.nur.repos.rycee.firefox-addons; [
      #   adsum-notabs
      #   bitwarden
      #   # duckduckgo-privacy-essentials
      #   # istilldontcareaboutcookies
      #   # immersive-translate # unfree
      #   # ublock-origin
      #   # vimium
      #   # vue-js-devtools
      # ];

      userChrome = ''
        #TabsToolbar { visibility: collapse !important; }
        #titlebar { visibility: collapse !important; }
        #sidebar-header { visibility: collapse !important; }
      '';

      # https://github.com/sherubthakur/dotfiles/tree/master/modules/firefox/config
      settings = {
        "app.update.auto" = false;

        "apz.gtk.kinetic_scroll.enabled" = false;
        "browser.gesture.pinch.in" = "";
        "browser.gesture.pinch.out" = "";
        "browser.gesture.pinch.in.shift" = "";
        "browser.gesture.pinch.out.shift" = "";

        "browser.fullscreen.autohide" = false;

        "browser.newtabpage.introShown" = false;
        "browser.shell.checkDefaultBrowser" = false;
        "browser.bookmarks.showMobileBookmarks" = false;
        "browser.aboutConfig.showWarning" = false;

        "browser.newtabpage.activity-stream.feeds.topsites" = false;
        "browser.newtabpage.activity-stream.improvesearch.topSiteSearchShortcuts" = false;
        # "startup.homepage_welcome_url" = "${./blank.html}";

        "browser.search.isUS" = false;
        "browser.search.region" = "DE";
        "browser.search.suggest.enabled" = false;

        "browser.sessionstore.resume_from_crash" = false;
        # "browser.startup.homepage" = "${./blank.html}";
        "browser.toolbars.bookmarks.visibility" = "never";
        "distribution.searchplugins.defaultLocale" = "en-US";
        "extensions.pocket.enabled" = false;
        "general.useragent.locale" = "en-US";

        # do not automatically block extensions on certain domains
        # TODO: is this really working?
        "extensions.quarantinedDomains.enabled" = false;

        # allow port 10080 access for qemu 80 host forward
        "network.security.ports.banned.override" = "10080";
        "privacy.trackingprotection.enabled" = true;
        "privacy.trackingprotection.socialtracking.annotate.enabled" = true;
        "privacy.trackingprotection.socialtracking.enabled" = true;

        "services.sync.declinedEngines" = "addons,passwords,prefs";
        "services.sync.engine.addons" = false;
        "services.sync.engine.passwords" = false;
        "services.sync.engine.prefs" = false;
        "services.sync.engineStatusChanged.addons" = true;

        "signon.rememberSignons" = false;

        "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
      };
    };
  };


}
