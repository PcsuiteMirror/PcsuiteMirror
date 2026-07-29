## PcsuiteMirror 0.0.5

Phone audio now plays on the Mac while mirroring — plus a Cancel button that
actually cancels, and three mirror-window/menu fixes.

### New
- **Phone audio on your Mac** — mirroring now carries sound. The phone mutes its
  own speaker and streams its system audio here (AAC-LC, decoded with
  AVAudioEngine), exactly the way the official client behaves.
- **Move the audio, live** — switch the sound between the phone and this Mac from
  the menu bar without interrupting the picture.
- **Mute this Mac** — a speaker button in the mirror window's title bar (and a
  menu item) silences playback locally while the phone keeps streaming.

### Fixed
- **Cancel did nothing when a Wi-Fi connect couldn't reach the phone** — e.g. a
  remembered device whose IP has since changed. Connecting is one long blocking
  call, and an unreachable host isn't refused, it's ignored: the OS retried the
  connection for ~75 seconds while the app sat on "Connecting…", queueing every
  other action behind it. Connect attempts are now abortable, Cancel takes effect
  immediately, and an unreachable phone fails in ~5s instead of ~75s.
- **Menu-bar dropdown kept refreshing while mirroring** — the per-second FPS /
  latency stats rebuilt the menu every second, closing whatever submenu the
  pointer was in and making it impossible to pick anything.
- **Mirror window's minimize button did nothing** — the window was missing the
  style flag AppKit requires to miniaturize it.
- **Mirror window's zoom (+) button did nothing** — it now toggles between
  filling the screen height and the previous size, keeping the phone's aspect
  ratio.

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
