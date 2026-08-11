import SwiftUI
import AppKit

/// Standard menu-bar dropdown. Every view here must be a native menu item
/// (Button / Toggle / Menu / Divider / Text) — SwiftUI renders them into an NSMenu.
struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(model.statusText)   // disabled status label
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
            // Device-centric: one submenu per remembered phone. The active device
            // exposes mirror/disconnect; the others expose connect options.
            ForEach(model.knownDevices) { dev in
                Menu(deviceLabel(dev)) { deviceMenu(dev) }
            }
            if !model.knownDevices.isEmpty { Divider() }
            // Add / connect a device not in the roster yet.
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

    /// Roster row label: device name, with a check mark when it's the active one.
    private func deviceLabel(_ dev: KnownDevice) -> String {
        (model.isConnected && dev.id == model.activeDeviceId) ? "✓ \(dev.menuLabel)" : dev.menuLabel
    }

    /// The expanded actions for one remembered device.
    @ViewBuilder private func deviceMenu(_ dev: KnownDevice) -> some View {
        if model.isConnected && dev.id == model.activeDeviceId {
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
        } else {
            Button(L("Connect over Wi-Fi")) { model.connect(dev, method: .lan) }
                .disabled((dev.lastIP ?? "").isEmpty)
            Button(L("Connect over USB")) { model.connect(dev, method: .usb) }
        }
        Divider()
        Button(L("Forget this device")) { model.forget(dev) }
    }
}
