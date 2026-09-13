import SwiftUI
import AppKit

/// Standard menu-bar dropdown. Every view here must be a native menu item
/// (Button / Toggle / Menu / Divider / Text) — SwiftUI renders them into an NSMenu.
struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // The status line. A failure is a row that copies its full text: the
        // row itself says only that it failed (a menu is as wide as its widest
        // row, and a core error runs to a full sentence), and a banner can't be
        // copied from. Once the line has reverted to Disconnected, the failure
        // stays one row below until the next attempt — the banner is usually
        // what brings the user here, seconds later.
        if case .failed = model.state {
            Button("\(model.statusText) — \(L("click to copy details"))") { model.copyFailure() }
        } else {
            Text(model.statusText)   // disabled status label
            if model.lastFailure != nil {
                Button("\(L("Last error")) — \(L("click to copy details"))") { model.copyFailure() }
            }
        }
        if let note = model.fileTransferNote {
            Text(note)           // transient file-transfer status
        }

        Divider()
        connectionItems

        Divider()
        Button(L("Settings…")) { PreferencesWindowController.shared.show(model: model) }
            .keyboardShortcut(",")

        Divider()
        Button(L("Quit")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder private var connectionItems: some View {
        if model.isBusy {
            Button(L("Cancel")) { model.cancelConnect() }
        } else {
            // Auto-reconnect (and the USB cable watch it parks on) is background
            // work, not a modal connect: the rest of the menu stays available —
            // Wi-Fi is often the way out of a cable that isn't coming back — with
            // one item to call it off.
            if model.isReconnecting || model.isWaitingForPhone {
                Button(model.isWaitingForPhone ? L("Stop waiting") : L("Stop reconnecting")) {
                    model.cancelConnect()
                }
                Divider()
            }
            // The live session before it is a roster row: the roster only learns
            // a phone's id from /base-info, which lands a moment after connect —
            // longer when the clipboard handshake runs first — and a first-time
            // phone has no row at all until then. The actions can't wait for it,
            // so until the row exists they hang off the connect target itself.
            if model.isConnected, let cur = model.lastDevice,
               !model.knownDevices.contains(where: { $0.id == model.activeDeviceId }) {
                Menu("✓ \(cur.displayName)") { sessionActions }
            }
            // Device-centric: one submenu per remembered phone. The active device
            // exposes mirror/disconnect; the others expose connect options.
            ForEach(model.knownDevices) { dev in
                Menu(deviceLabel(dev)) { deviceMenu(dev) }
            }
            if model.isConnected || !model.knownDevices.isEmpty { Divider() }
            // Account mode: every phone on the account, one click to connect at
            // the address it last reported. Flat rows on purpose — the roster
            // above has the per-device actions; this is the shortcut.
            if model.cloudAccountActive {
                Text(L("Phones on this account"))
                if model.cloudPhones.isEmpty {
                    Text(L("No phones listed yet."))
                }
                ForEach(model.cloudPhones) { phone in
                    Button(cloudPhoneLabel(phone)) { model.connectCloud(phone) }
                        .disabled(phone.ip.isEmpty || isActive(phone))
                }
                Button(L("Refresh phone list")) { model.refreshCloudPhones() }
                Divider()
            }
            // The manual ways in (QR / cable / typed IP), for a phone not in the
            // roster yet. Serverless mode only: in account mode the phones and
            // their addresses come from the account list above.
            if model.serverlessMode {
                Menu(L("New Connect")) {
                    Button(L("Pair new device (QR)…")) { model.pairQR() }
                    Button(L("Connect over USB")) { model.connectUSB() }
                    Button(L("Connect over Wi-Fi…")) {
                        if let ip = promptForIP(default: model.lanIP) {
                            let t = ip.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !t.isEmpty { model.lanIP = t; model.connectLAN() }
                        }
                    }
                }
            }
        }
    }

    /// Roster row label: device name, with a check mark when it's the active one.
    private func deviceLabel(_ dev: KnownDevice) -> String {
        (model.isConnected && dev.id == model.activeDeviceId) ? "✓ \(dev.menuLabel)" : dev.menuLabel
    }

    /// Account row label: "iQOO 15 · 192.168.31.250", check-marked while connected
    /// to it; a phone that reported no address says so (and is disabled).
    private func cloudPhoneLabel(_ phone: CloudDevice) -> String {
        let name = phone.name.isEmpty ? phone.model : phone.name
        let addr = phone.ip.isEmpty ? L("no address reported") : phone.ip
        return (isActive(phone) ? "✓ " : "") + "\(name) · \(addr)"
    }

    /// Whether the live session is to this account phone. The account list has no
    /// id in common with the roster, so match on what the connect used: the
    /// address, or failing that the name.
    private func isActive(_ phone: CloudDevice) -> Bool {
        guard model.isConnected, let cur = model.lastDevice, cur.transport == .lan else { return false }
        // A Tailscale session is at an address the list never carries; the name
        // is all there is to go on.
        if cur.remote != true, let ip = cur.ip, !ip.isEmpty { return ip == phone.ip }
        return !phone.name.isEmpty && cur.name == phone.name
    }

    /// What can be done with the live session: mirror, send files, audio, disconnect.
    @ViewBuilder private var sessionActions: some View {
        if let info = model.deviceInfo {
            Text("\(L("Storage")) \(info.storageSummary)")
        }
        Button(model.mirroring ? L("Stop mirroring") : L("Start mirroring")) {
            if model.mirroring { model.closeMirror() } else { model.openMirror() }
        }
        Button(L("Send Files to Phone…")) { model.pushFiles(pickFilesToSend()) }
        // Where the sound comes out. Switchable live — the picture keeps running.
        Button(model.audioEnabled ? L("Move audio back to phone") : L("Move audio to this Mac")) {
            model.setAudio(!model.audioEnabled)
        }
        if model.audioEnabled {
            Button(model.audioMuted ? L("Unmute this Mac") : L("Mute this Mac")) {
                model.toggleAudioMuted()
            }
        }
        Button(L("Disconnect")) { model.disconnect() }
    }

    /// The expanded actions for one remembered device.
    @ViewBuilder private func deviceMenu(_ dev: KnownDevice) -> some View {
        if model.isConnected && dev.id == model.activeDeviceId {
            sessionActions
        } else {
            // One entry, not a transport menu: the app can tell which route is
            // available faster than the user can, and picking wrong is the common
            // mistake (a cable that isn't plugged in produces an adb diagnostic).
            // Cable first, then Wi-Fi at the freshest address, then Tailscale if
            // the user gave one — see connectAuto.
            Button(L("Connect")) { model.connectAuto(dev) }
        }
        Divider()
        // The one address the app can't learn on its own: the phone's Tailscale
        // one, used only after the cable and Wi-Fi have both failed.
        if let ts = dev.tailscale {
            Text("Tailscale · \(ts)")
        }
        Button(dev.tailscale == nil ? L("Set Tailscale address…") : L("Change Tailscale address…")) {
            if let ip = promptForTailscaleIP(default: dev.tailscale ?? "") {
                model.setTailscaleIP(dev, ip)
            }
        }
        Button(L("Forget this device")) { model.forget(dev) }
    }
}
