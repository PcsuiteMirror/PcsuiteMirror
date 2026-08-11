import SwiftUI
import AppKit

/// Push the persisted account identity + per-phone seeds into the Rust core.
/// Call right before *any* connect: the LAN sign needs the openID, and so does the
/// super-clipboard (it only syncs within one vivo account) — so USB needs the
/// openID too even though its *connection* doesn't. Runs on the caller's thread
/// (the connect queue); the core guards the overrides with a lock.
func applyIdentityToCore() {
    // Mode + account first: in vivo-account mode the openID below is the one the
    // sign-in supplied, and the core must know which mode it's in either way.
    applyAccountToCore()
    pcsuite_set_identity(Store.openID, Store.pcMac, Store.accountLabel, Store.deviceName)
    pcsuite_set_clip_id(Store.clipPcId)
    for e in Store.seeds {
        let ip = e.ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else { continue }
        pcsuite_set_seed(ip, e.seed.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Settings panel for the LAN pairing identity. USB needs none of this; only the
/// Wi-Fi path presents an account `openID` (+ optional per-phone seed) to the phone.
struct LanSettingsView: View {
    var onDone: () -> Void

    @State private var openID = Store.openID
    @State private var deviceName = Store.deviceName
    @State private var pcMac = Store.pcMac
    @State private var account = Store.accountLabel
    @State private var clipPcId = Store.clipPcId
    @State private var useRemote = Store.lanUseRemote
    @State private var seeds = Store.seeds

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(L("Account openID"), text: $openID)
                    TextField(L("Clipboard PC id"), text: $clipPcId)
                    TextField(L("Device name"), text: $deviceName)
                    TextField(L("PC MAC (optional)"), text: $pcMac)
                    TextField(L("Account label (optional)"), text: $account)
                } header: {
                    Text(L("Account identity"))
                } footer: {
                    Text(L("openID is per vivo-account (same for every phone on it), required for Wi-Fi connect AND clipboard (incl. USB — shared clipboard is account-scoped). Clipboard PC id must match the id the phone registered for this Mac at pairing, or phone→Mac clipboard won't sync. Mac/name aren't validated."))
                }

                Section {
                    Toggle(L("Connect without a seed (connectType=1)"), isOn: $useRemote)
                } footer: {
                    Text(L("Recommended for a new device — needs only the openID. Turn off to use the per-phone seed below (connectType=2)."))
                }

                Section {
                    ForEach($seeds) { $e in
                        HStack {
                            TextField("192.168.x.x", text: $e.ip).frame(width: 130)
                            TextField(L("seed UUID"), text: $e.seed)
                            Button {
                                seeds.removeAll { $0.id == e.id }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button {
                        seeds.append(SeedEntry(ip: "", seed: ""))
                    } label: { Label(L("Add phone seed"), systemImage: "plus") }
                } header: {
                    Text(L("Per-phone seeds (connectType=2)"))
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("Done")) { save(); onDone() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 440)
    }

    private func save() {
        Store.openID = openID.trimmingCharacters(in: .whitespacesAndNewlines)
        Store.clipPcId = clipPcId.trimmingCharacters(in: .whitespacesAndNewlines)
        Store.deviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        Store.pcMac = pcMac.trimmingCharacters(in: .whitespacesAndNewlines)
        Store.accountLabel = account.trimmingCharacters(in: .whitespacesAndNewlines)
        Store.lanUseRemote = useRemote
        Store.seeds = seeds.filter { !$0.ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Consolidated settings window: the feature toggles and pickers that used to live
/// in the menu-bar dropdown (most are set once and rarely touched). Bound directly
/// to the shared `AppModel`, so each change persists immediately and the menu stays
/// in sync — there is no Save step. The account identity (rarely needed now that the
/// openID self-fills on connect) is tucked behind the "Identity / account…" link.
struct PreferencesView: View {
    @ObservedObject var model: AppModel
    var onIdentity: () -> Void
    var onAccount: () -> Void

    /// `model.resolution` is `private(set)` (changing it may restart the live
    /// stream), so route the picker through `setResolution(_:)`.
    private var resolution: Binding<MirrorResolution> {
        Binding(get: { model.resolution }, set: { model.setResolution($0) })
    }
    private var bitrate: Binding<MirrorBitrate> {
        Binding(get: { model.bitrate }, set: { model.setBitrate($0) })
    }
    private var frameRate: Binding<MirrorFrameRate> {
        Binding(get: { model.frameRate }, set: { model.setFrameRate($0) })
    }
    private var audio: Binding<Bool> {
        Binding(get: { model.audioEnabled }, set: { model.setAudio($0) })
    }
    private var preset: Binding<MirrorPreset> {
        Binding(get: { model.currentPreset }, set: { model.applyPreset($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle(L("Clipboard sync"), isOn: $model.clipboardEnabled)
                    Picker(L("Clipboard direction"), selection: $model.clipboardDirection) {
                        ForEach(ClipboardDirection.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(!model.clipboardEnabled)
                    Toggle(L("Verify-code relay"), isOn: $model.verifyEnabled)
                    Toggle(L("Notification relay"), isOn: $model.notifyEnabled)
                } header: {
                    Text(L("Sync"))
                }

                Section {
                    Toggle(L("Auto-reconnect last device"), isOn: $model.autoReconnect)
                    Picker(L("Mirror preset"), selection: preset) {
                        ForEach(MirrorPreset.allCases) { Text($0.label).tag($0) }
                    }
                    Picker(L("Mirror resolution"), selection: resolution) {
                        ForEach(MirrorResolution.allCases) { Text($0.label).tag($0) }
                    }
                    Picker(L("Mirror bitrate"), selection: bitrate) {
                        ForEach(MirrorBitrate.allCases) { Text($0.label).tag($0) }
                    }
                    Picker(L("Mirror frame rate"), selection: frameRate) {
                        ForEach(MirrorFrameRate.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle(L("Play phone audio on this Mac"), isOn: audio)
                    Text(L("The phone mutes its own speaker while streaming audio."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(L("Show FPS & latency"), isOn: $model.showStats)
                } header: {
                    Text(L("Connection"))
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button(L("Identity / account…")) { onIdentity() }
                    .buttonStyle(.link)
                Button(L("Account & mode…")) { onAccount() }
                    .buttonStyle(.link)
                Spacer()
            }
            .padding(12)
        }
        .frame(width: 440, height: 360)
    }
}

/// Hosts `PreferencesView` in a plain window (menu-bar apps have no window by
/// default). Holds the shared model so the toggles bind to live app state.
final class PreferencesWindowController {
    static let shared = PreferencesWindowController()
    private var window: NSWindow?

    func show(model: AppModel) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: PreferencesView(
            model: model,
            onIdentity: { SettingsWindowController.shared.show() },
            onAccount: {
                VivoAccountWindowController.shared.show { ip in
                    guard !ip.isEmpty else { return }
                    model.lanIP = ip
                    model.connectLAN()
                }
            }
        ))
        let w = NSWindow(contentViewController: host)
        w.title = L("Settings")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Hosts `LanSettingsView` in a plain window. A menu-bar (`.accessory`) app has no
/// window by default, so we create one on demand and bring it to the front.
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: LanSettingsView(onDone: { [weak self] in
            self?.window?.close()
        }))
        let w = NSWindow(contentViewController: host)
        w.title = L("Identity")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
