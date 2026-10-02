## PcsuiteMirror 0.1.8

The mirror window now understands the usual editing shortcuts.

### New
- **⌘A / ⌘X / ⌘C in the mirror** — select all, cut and copy now act on the
  phone (sent as Ctrl+A / X / C, which the phone's text fields understand). The
  same commands in the menu bar's *Edit* menu work too.
- **⌘V pastes into the phone** — the text on the Mac clipboard is typed straight
  into the phone's focused field, so it works right away and even with clipboard
  sync turned off. If the Mac clipboard holds no text, ⌘V pastes the phone's own
  clipboard instead. Like typing, this only works when a text field on the phone
  has focus.

### Fixed
- **Backspace deletes the selection** — with text selected on the phone,
  backspace used to delete the character before the selection and leave the
  selected text in place. It now deletes the selected text, like a hardware
  keyboard.

### Requirements
- macOS 13 (Ventura) or later; collapsible sidebar groups and menu group titles
  need macOS 14
- **Apple Silicon (arm64)** — this build is arm64-only
- USB: just plug in and authorize USB debugging. Wi-Fi: set your vivo-account
  `openID` once in the menu-bar identity settings (see the README).

### Install
If you have 0.1.6 or later, the app offers this update itself — click
*Update available* in the menu (or *Check for Updates…*).

Otherwise: the build is signed with a Developer ID certificate and **notarized by
Apple**, so it opens normally:

1. Quit any running PcsuiteMirror, open the `.dmg` and drag
   **PcsuiteMirror.app** to **Applications** (replace the old copy).
2. Launch it from Applications. (It's a menu-bar app — look for its icon in the
   menu bar, not the Dock.)

The `.zip` is the same notarized app if you prefer that over the disk image.

### License
GPLv3 — Copyright (C) 2026 xVanTuring.
