## PcsuiteMirror 0.1.4

USB connections now count as real connections on the phone, the app refuses to
run twice, and a "Files received" banner takes you to the files.

### Fixed
- **USB session invisible to the phone's connection center** — while connected
  over a cable, the phone still listed this Mac as not connected (with a
  「连接」 button), and files shared from the phone went through 云传输 (vivo's
  cloud relay) instead of straight over the cable. The USB connect sent only a
  minimal `/base-info` without the account fields. It now sends the same full
  `/version` + `/base-info` handshake as a Wi-Fi connect (signed-in account,
  `pcSystemType` "2"), so the phone treats the USB session as connected and
  sends files directly.
- **Clicking a notification could start a second copy of the app** — with more
  than one copy installed, macOS may launch a different one on a banner click.
  The new instance's USB reconnect restarted the phone app, dropping the first
  instance's session, and the two kept knocking each other off. The app now
  runs as a single instance (an exclusive lock file under Application Support):
  a second launch brings the running copy forward and quits before connecting.

### New
- **Click "Files received" to see the files** — opens the save folder in Finder
  with that batch selected. Files moved or deleted since are skipped; if none
  are left, the folder itself opens.

### Requirements
- macOS 13 (Ventura) or later
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
