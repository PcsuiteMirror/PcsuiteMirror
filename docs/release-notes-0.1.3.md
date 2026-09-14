## PcsuiteMirror 0.1.3

One fix, in the core: the clipboard no longer stays dead for a whole session
when the phone misses the handshake.

### Fixed
- **Clipboard silently off after a quick reconnect** — seen on a real phone: a
  session closed and reopened a few seconds later (a Tailscale session, then
  Wi-Fi) got no answer to the clipboard handshake, so neither direction synced
  until the user disconnected and reconnected by hand. The phone's clipboard
  service only picks the handshake up once it has re-registered with PCSuite,
  and a `startup` that lands before that is simply lost. The core now re-sends
  the same `startup` (same keys — nothing is rotated, and the phone re-parses it
  idempotently) after 3 s without a reply, up to twice, then keeps listening.
  The device-id wait that file receiving and the storage panel depend on now
  covers that whole window, so they come up together with the clipboard instead
  of failing alongside it.

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
