## PcsuiteMirror 0.1.5

Browse and manage the phone's files from the Mac, and send files by dropping
them on the menu-bar icon.

### New
- **Phone file browser** — *Browse Phone Files…* in the device menu opens a
  native window (Finder-style sidebar, toolbar and path bar):
  - Folders from the phone's storage root, plus shortcuts to Camera and
    Downloads; Recent, Photos, Videos, Audio and Documents; and the phone
    gallery's albums with their item counts. Sidebar groups fold like Finder's.
  - Sortable list with thumbnails for photos and videos, and a filter field.
  - Get files out: *Download…* (⌘S) to a folder you pick, ⌘C then paste in
    Finder, or drag rows straight onto Finder. Folders download whole, streamed
    to disk, with overall progress.
  - Put files in: drag files or folders into the window (or use *Upload*) to
    upload into the folder you're viewing.
  - New Folder (⇧⌘N), Rename, and Delete (⌘⌫, always asks first).
  - Works over USB and Wi-Fi.
- **Drop files on the menu-bar icon** — dragging files over the icon opens a
  panel of your phones. Drop on one to send; a phone that isn't connected is
  connected first (cable, Wi-Fi, then Tailscale), and the files go only once
  that same phone is on the line. Releasing on the icon sends to the connected
  phone; dropping on the panel sends to the only phone listed, or holds the
  files until you click one.

### Changed
- **Device menu grouped** — Streaming (mirroring, audio) and Files (storage,
  browse, send) are separate groups, with Disconnect last.
- **Send Files to Phone** now accepts folders.

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
