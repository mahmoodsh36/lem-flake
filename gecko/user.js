// prefs for lem-gecko's own firefox profile, rewritten on every launch

// hide firefox's ui around the editor page
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
user_pref("browser.tabs.inTitlebar", 0);
user_pref("browser.startup.page", 0);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);

// 1 lets the page handle escape, C-w, C-t, C-n... (2 blocks them), and keep alt from the menu bar
user_pref("permissions.default.shortcuts", 1);
user_pref("ui.key.menuAccessKeyFocuses", false);

// firefox snapshots top sites in a hidden browser when idle. a snapshot of lem's page logs in as a
// second client and resets the cell size the real window is drawn with
user_pref("browser.pagethumbnails.capturing_disabled", true);
user_pref("browser.newtabpage.activity-stream.feeds.topsites", false);
user_pref("browser.newtabpage.activity-stream.feeds.system.topsites", false);
user_pref("browser.newtabpage.enabled", false);
