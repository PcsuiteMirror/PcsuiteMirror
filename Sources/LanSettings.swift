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

// MARK: - Identity tab

/// The LAN pairing identity as one editable value, so the tab can load it in one
/// go and write it back on any change — a tab has no Done button to save on.
private struct IdentityDraft: Equatable {
    var openID = ""
    var clipPcId = ""
    var deviceName = ""
    var pcMac = ""
    var account = ""
    var useRemote = true
    var seeds: [SeedEntry] = []

    static func load() -> IdentityDraft {
        IdentityDraft(openID: Store.openID, clipPcId: Store.clipPcId,
                      deviceName: Store.deviceName, pcMac: Store.pcMac,
                      account: Store.accountLabel, useRemote: Store.lanUseRemote,
                      seeds: Store.seeds)
    }

    func save() {
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        Store.openID = trim(openID)
        Store.clipPcId = trim(clipPcId)
        Store.deviceName = trim(deviceName)
        Store.pcMac = trim(pcMac)
        Store.accountLabel = trim(account)
        Store.lanUseRemote = useRemote
        // A row still being typed keeps its place in the draft; only rows with an
        // address are worth persisting.
        Store.seeds = seeds.filter { !trim($0.ip).isEmpty }
    }
}

/// The LAN pairing identity. USB needs none of this; only the Wi-Fi path presents
/// an account `openID` (+ optional per-phone seed) to the phone. Edits persist as
/// they're made and reach the core at the next connect (`applyIdentityToCore`).
struct IdentityTab: View {
    @State private var draft = IdentityDraft.load()

    var body: some View {
        Form {
            Section {
                TextField(L("Account openID"), text: $draft.openID)
                TextField(L("Clipboard PC id"), text: $draft.clipPcId)
                TextField(L("Device name"), text: $draft.deviceName)
                TextField(L("PC MAC (optional)"), text: $draft.pcMac)
                TextField(L("Account label (optional)"), text: $draft.account)
            } header: {
                Text(L("Account identity"))
            } footer: {
                Text(L("openID is per vivo-account (same for every phone on it), required for Wi-Fi connect AND clipboard (incl. USB — shared clipboard is account-scoped). Clipboard PC id must match the id the phone registered for this Mac at pairing, or phone→Mac clipboard won't sync. Mac/name aren't validated."))
            }

            Section {
                Toggle(L("Connect without a seed (connectType=1)"), isOn: $draft.useRemote)
            } footer: {
                Text(L("Recommended for a new device — needs only the openID. Turn off to use the per-phone seed below (connectType=2)."))
            }

            Section {
                ForEach($draft.seeds) { $e in
                    HStack {
                        TextField("192.168.x.x", text: $e.ip).frame(width: 130)
                        TextField(L("seed UUID"), text: $e.seed)
                        Button {
                            draft.seeds.removeAll { $0.id == e.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button {
                    draft.seeds.append(SeedEntry(ip: "", seed: ""))
                } label: { Label(L("Add phone seed"), systemImage: "plus") }
            } header: {
                Text(L("Per-phone seeds (connectType=2)"))
            }
        }
        .formStyle(.grouped)
        // Sign-in fills the openID / clipboard id behind this tab's back; re-read
        // whenever the tab comes into view so it never shows stale values.
        .onAppear { draft = .load() }
        .onChange(of: draft) { $0.save() }
    }
}

// MARK: - Settings window

/// The tabs, in toolbar order. Each carries the SF Symbol and the height its
/// content wants — the window resizes to the selected tab, Preferences-style.
enum PreferencesTab: Int, CaseIterable {
    case general, mirroring, notifications, identity, account

    var title: String {
        switch self {
        case .general: return L("General")
        case .mirroring: return L("Mirroring")
        case .notifications: return L("Notifications")
        case .identity: return L("Identity")
        case .account: return L("Account")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .mirroring: return "rectangle.on.rectangle"
        case .notifications: return "bell.badge"
        case .identity: return "person.text.rectangle"
        case .account: return "person.crop.circle"
        }
    }
    var height: CGFloat {
        switch self {
        case .general: return 420
        case .mirroring: return 470
        case .notifications: return 300
        case .identity: return 540
        case .account: return 580
        }
    }

    @ViewBuilder func content(_ model: AppModel) -> some View {
        switch self {
        case .general: GeneralTab(model: model)
        case .mirroring: MirroringTab(model: model)
        case .notifications: NotificationsTab(model: model)
        case .identity: IdentityTab()
        case .account: AccountTab(appModel: model)
        }
    }
}

/// Feature toggles bound straight to the shared `AppModel`, so each change
/// persists immediately and the menu stays in sync — there is no Save step.
struct GeneralTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var updater = UpdaterService.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("Launch at login"), isOn: $model.launchAtLogin)
                Toggle(L("Auto-reconnect last device"), isOn: $model.autoReconnect)
                Stepper(value: $model.reconnectLimit, in: 1...10) {
                    Text("\(L("Reconnect attempts")): \(model.reconnectLimit)")
                }
                .disabled(!model.autoReconnect)
            } header: {
                Text(L("Startup"))
            } footer: {
                Text(L("Each attempt checks whether the phone is reachable before dialing, so 1 is usually enough — a phone that isn't on the network won't appear on a retry."))
            }

            Section {
                Toggle(L("Clipboard sync"), isOn: $model.clipboardEnabled)
                Picker(L("Clipboard direction"), selection: $model.clipboardDirection) {
                    ForEach(ClipboardDirection.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!model.clipboardEnabled)
                Toggle(L("Verify-code relay"), isOn: $model.verifyEnabled)
            } header: {
                Text(L("Sync"))
            }

            Section {
                Toggle(L("Automatically check for updates"),
                       isOn: Binding(get: { updater.autoCheck }, set: { updater.setAutoCheck($0) }))
                LabeledContent(L("Current version"),
                               value: "\(updater.currentVersion) (\(updater.currentBuild))")
                Button(L("Check for Updates…")) { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            } header: {
                Text(L("Updates"))
            } footer: {
                Text(L("Updates are signed and verified before they install. A background check that finds one shows it in the menu instead of interrupting you."))
            }

            Section {
                Button(L("Reset all settings…")) { confirmReset() }
                    .foregroundStyle(.red)
            } footer: {
                Text(L("Signs out, forgets every phone and the LAN identity, and restores every default."))
            }
        }
        .formStyle(.grouped)
    }

    /// Ask first: this signs the account out and forgets every phone, and
    /// there is no undo.
    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = L("Reset all settings?")
        alert.informativeText = L("This disconnects the phone, signs out of the vivo account, forgets every paired phone and the LAN identity, and puts every option back to its default. The app keeps running.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Reset")).hasDestructiveAction = true
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.resetAllSettings()
    }
}

/// Which events put a banner on this Mac. The phone-notification switch doubles
/// as the relay feature toggle (the phone only forwards them while it's on) — it
/// lives here rather than under Sync because a banner is all it produces.
/// Failures are not switchable: they are always shown.
struct NotificationsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle(L("Device connected"), isOn: $model.notifyOnConnect)
                Toggle(L("Files sent or received"), isOn: $model.notifyOnFileTransfer)
                Toggle(L("Phone notifications"), isOn: $model.notifyEnabled)
            } header: {
                Text(L("Show a notification for"))
            } footer: {
                Text(L("Failures — a connect that didn't work, a transfer that didn't finish — are always reported. Phone notifications are forwarded by the phone only while that switch is on."))
            }
        }
        .formStyle(.grouped)
    }
}

/// Picture / audio / diagnostics knobs for the mirror stream.
struct MirroringTab: View {
    @ObservedObject var model: AppModel

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
        Form {
            Section {
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
            } header: {
                Text(L("Picture"))
            }

            Section {
                Toggle(L("Play phone audio on this Mac"), isOn: audio)
            } header: {
                Text(L("Audio"))
            } footer: {
                Text(L("The phone mutes its own speaker while streaming audio."))
            }

            Section {
                Toggle(L("Show FPS & latency"), isOn: $model.showStats)
            } header: {
                Text(L("Diagnostics"))
            }
        }
        .formStyle(.grouped)
    }
}

/// The settings window: a Preferences-style toolbar (icon + label per tab) over
/// one SwiftUI tab each. AppKit's `NSTabViewController` in `.toolbar` style is
/// what gives that look — SwiftUI's `TabView` on macOS renders text-only
/// segments — and it resizes the window to each tab's content for free.
final class PreferencesWindowController {
    static let shared = PreferencesWindowController()
    private static let width: CGFloat = 520
    private var window: NSWindow?
    private var tabs: NSTabViewController?

    /// Open the window (or bring it forward) on `tab`; nil keeps the current tab.
    func show(model: AppModel, tab: PreferencesTab? = nil) {
        if window == nil { build(model) }
        if let tab { tabs?.selectedTabViewItemIndex = tab.rawValue }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build(_ model: AppModel) {
        let tvc = NSTabViewController()
        tvc.tabStyle = .toolbar
        // The selected tab's title becomes the window title, as in Preferences.
        tvc.canPropagateSelectedChildViewControllerTitle = true
        for tab in PreferencesTab.allCases {
            let size = NSSize(width: Self.width, height: tab.height)
            let host = NSHostingController(rootView: tab.content(model).frame(width: size.width, height: size.height))
            host.title = tab.title
            host.preferredContentSize = size
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tvc.addTabViewItem(item)
        }
        let w = NSWindow(contentViewController: tvc)
        w.title = L("Settings")
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        tabs = tvc
    }

    /// Close and drop the window so the next `show()` builds it afresh — the
    /// Identity and Account tabs snapshot the store when created.
    func discard() {
        window?.close()
        window = nil
        tabs = nil
    }
}
