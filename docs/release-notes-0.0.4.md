## PcsuiteMirror 0.0.4

A clipboard bugfix release: Chinese (and other non-Latin) text copied from the
phone no longer arrives garbled on a freshly-installed Mac.

### Fixed
- **Garbled Chinese clipboard text** — text copied from the phone could land on
  the Mac clipboard as mojibake (e.g. `@香菜爆炒蟑螂` showing up as
  `@È¶ôËèúÁàÜÁÇíËûÇ`). The clipboard backend shells out to `pbcopy`/`pbpaste`,
  which pick their text encoding from the process locale and **fall back to Mac
  OS Roman** when none is set — and a menu-bar app launched by macOS inherits no
  locale, so UTF-8 bytes were being decoded as Mac Roman. Both the phone→Mac and
  Mac→phone directions now pin **`LC_CTYPE=UTF-8`**, so text round-trips
  correctly regardless of the machine's locale settings.

### Requirements
- macOS 13 (Ventura) or later
- **Apple Silicon (arm64)** — this build is arm64-only
- USB: just plug in and authorize USB debugging. Wi-Fi: set your vivo-account
  `openID` once in the menu-bar identity settings (see the README).

### Install
Signed with a Developer ID certificate and **notarized by Apple**, so it opens
normally — no Gatekeeper right-click dance:

1. Open the `.dmg` and drag **PcsuiteMirror.app** to **Applications**.
2. Launch it from Applications. (It's a menu-bar app — look for its icon in the
   menu bar, not the Dock.)

The `.zip` is the same notarized app if you prefer that over the disk image.

### License
GPLv3 — Copyright (C) 2026 xVanTuring.
