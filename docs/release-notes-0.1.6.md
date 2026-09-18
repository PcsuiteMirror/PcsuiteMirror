## PcsuiteMirror 0.1.6

PcsuiteMirror now updates itself.

### New
- **Automatic updates** — the app checks for new versions once a day. When one
  is found it doesn't interrupt you: an *Update available* item appears in the
  menu, and clicking it shows the release notes and installs the update. Every
  update is signature-checked before it installs.
  - *Check for Updates…* in the menu checks right away.
  - Settings → General → Updates turns automatic checks on or off and shows the
    current version.
  - This is the last version you need to install by hand; later ones arrive
    through the app.

### Changed
- **Clipboard diagnostics** — when the phone sends clipboard data the app can't
  read, the log now records what arrived, to help track down cases where the
  Mac's clipboard stops reaching the phone until something is copied on the
  phone.

### Requirements
- macOS 13 (Ventura) or later; collapsible sidebar groups and menu group titles
  need macOS 14
- **Apple Silicon (arm64)** — this build is arm64-only
- USB: just plug in and authorize USB debugging. Wi-Fi: set your vivo-account
  `openID` once in the menu-bar identity settings (see the README).

### Install
Signed with a Developer ID certificate and **notarized by Apple**, so it opens
normally — no Gatekeeper right-click dance:

1. Quit any running PcsuiteMirror, open the `.dmg` and drag
   **PcsuiteMirror.app** to **Applications** (replace the old copy).
2. Launch it from Applications. (It's a menu-bar app — look for its icon in the
   menu bar, not the Dock.)

The `.zip` is the same notarized app if you prefer that over the disk image.

### License
GPLv3 — Copyright (C) 2026 xVanTuring.
