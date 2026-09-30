## PcsuiteMirror 0.1.7

The mirror window now keeps up with the new macOS look, and can be resized.

### New
- **Zoom the mirror from the keyboard** — ⌘+ makes the mirror window bigger,
  ⌘- makes it smaller (10% per step), and ⌘0 returns it to the default size.
  The window stays centred and on screen.

### Fixed
- **Window buttons match the system** — the close / minimize / zoom buttons on
  the mirror window are now the system's own, so they follow the current macOS
  design (including macOS 27): size, spacing, the symbols shown on hover, and
  the grey look when the window is in the background.
- **Resizing the window scales the picture** — dragging an edge or corner of the
  mirror window used to cut off the title bar instead of resizing the picture.
  The picture now scales with the window and keeps the phone's aspect ratio;
  dragging a corner no longer flickers.

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
