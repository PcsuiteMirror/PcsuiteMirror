## PcsuiteMirror 0.0.3

A screen-mirror stability release: the mirror window now handles a locked
phone gracefully and no longer gets stuck mid-swipe when you drag outside it.

### Fixed
- **Locked-phone mirroring** — when the phone is locked, the mirror window now
  shows a **"Unlock your phone"** overlay instead of a black frame, and
  **auto-resumes** the moment the first frame arrives after you unlock. Window
  controls (traffic-light buttons / navigation keys) stay available so you can
  move or close it, the black-screen restart watchdog is suppressed while
  locked, and the system pointer is restored (the frame isn't interactive until
  unlock).
- **Stuck swipe when dragging out of the window** — dragging past the edge of
  the borderless mirror window and releasing there used to drop the mouse-up
  event, so the phone thought your finger was still down and a page/scroll got
  stuck halfway. Input now pulls the drag/release events directly (modal event
  tracking) whether or not the cursor is inside the window, clamps to the frame
  edge, and always delivers a complete **press → move → release** gesture.

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
