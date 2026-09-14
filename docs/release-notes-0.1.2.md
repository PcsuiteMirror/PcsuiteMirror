## PcsuiteMirror 0.1.2

Phone audio without the picture, and a Wi-Fi phone that walked out of range is
now waited for instead of given up on.

### New
- **Play phone audio only (no picture)** — a menu item that streams the phone's
  sound to this Mac without opening the mirror window: music or a call with the
  phone left in a pocket. The phone only streams audio on an open mirror stream,
  so one is opened at the cheapest settings (720 / 4 Mbps / 30 fps) and the
  video is dropped on arrival, undecoded. To the phone it is an ordinary cast —
  its own speaker goes quiet and its 「投屏中」 notice shows. "Start mirroring"
  takes it over; the phone's own 「关闭投屏」 ends it; an auto-reconnect resumes it.
- **Waits for a Wi-Fi phone that dropped out** — when a Wi-Fi session is lost
  because the link went (not because the phone or you ended it) and the
  reconnect attempts run out, the app no longer reports a failure. It parks on
  "Waiting for <phone> to come back…" and checks the phone's addresses (the
  account list's current one, the remembered Wi-Fi one, Tailscale) every 20 s —
  sooner when the account list reports a new address or the discoverability
  hold reaches the phone — and dials back in as soon as one answers. A dial that
  fails doubles the interval (up to 2 min). "Stop waiting", a connect of your
  own, or switching auto-reconnect off ends the wait.

### Fixed
- **Discoverable again while waiting** — during the USB cable wait the
  background "discoverable" connection was dropped, so the phone listed this Mac
  as 「未发现」 until the cable came back. A wait has nothing in flight, so the
  hold now stays up through it (and through the new Wi-Fi wait).
- **Mirror-window overlay text** was Chinese in both languages; it is now
  localized, and it says when the phone is being waited for rather than just
  "connection lost".

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
