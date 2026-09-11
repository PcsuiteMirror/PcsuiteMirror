import Foundation
import AVFoundation
import SwiftUI

/// Mirror-window link status, surfaced so the window can show a reconnect overlay
/// instead of a frozen picture when the connection drops mid-mirror.
enum MirrorLink: Equatable {
    case live          // streaming normally (or no mirror window open)
    case reconnecting  // the link dropped; an auto-reconnect is in progress
    case lost          // the link dropped and we are not (or no longer) reconnecting
}

/// Observable app state + intent surface for the UI. All mutations happen on the
/// main thread (SwiftUI actions, plus controller callbacks which hop to main).
final class AppModel: ObservableObject {
    // Connection / mirroring state.
    @Published private(set) var state: ConnState = .disconnected
    @Published private(set) var mirroring = false
    @Published private(set) var displayLayer: AVSampleBufferDisplayLayer?
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var lastCode: String?
    /// Phone-reported secure-screen token ("" / "clear" = none; "password",
    /// "safety", "lockScreen" = a privacy screen the phone handles itself).
    @Published private(set) var privacyState: String = ""
    /// Whether the phone's keyguard is locked (no frames until the user unlocks).
    /// Tracked separately from `privacyState`: the phone reports its foreground-window
    /// privacy as "clear" even while locked, so a single token can't carry both.
    @Published private(set) var screenLocked: Bool = false
    /// Mirror-window link status (drives the reconnect overlay).
    @Published private(set) var mirrorLink: MirrorLink = .live
    /// Phone device info (storage capacity, model, OS) for the connected device;
    /// nil when disconnected. Fetched shortly after connect.
    @Published private(set) var deviceInfo: PhoneInfo?
    /// Light file-transfer status line ("Sending…" / "Sent…" / "Received…"),
    /// shown in the menu for a few seconds; nil when idle.
    @Published private(set) var fileTransferNote: String?

    // Persisted preferences (default ON).
    // Turning it off must also stop a sequence that is already running — including
    // a USB cable watch, which would otherwise sit there forever, and an attempt
    // already in flight, whose late failure would otherwise arrive looking like a
    // connect the user had asked for (and pop a notification for it).
    @Published var autoReconnect: Bool {
        didSet {
            Store.autoReconnect = autoReconnect
            guard !autoReconnect, reconnectDevice != nil else { return }
            let showing = mirror.isShowing
            cancelConnect()
            mirrorLink = showing ? .lost : .live
        }
    }
    // Feature toggles apply to a live session immediately (no reconnect needed);
    // didSet only fires on user changes, never during init.
    @Published var clipboardEnabled: Bool { didSet { Store.clipboardEnabled = clipboardEnabled; applyClipboardLive() } }
    @Published var clipboardDirection: ClipboardDirection { didSet { Store.clipboardDirection = clipboardDirection; applyClipboardLive() } }
    @Published var verifyEnabled: Bool { didSet { Store.verifyEnabled = verifyEnabled; if isConnected { controller.setVerify(enabled: verifyEnabled) } } }
    @Published var notifyEnabled: Bool { didSet { Store.notifyEnabled = notifyEnabled; if isConnected { controller.setNotify(enabled: notifyEnabled) } } }
    /// Show the FPS / latency HUD over the mirror picture.
    @Published var showStats: Bool { didSet { Store.showStats = showStats } }
    /// Open at login. Not in the store: the OS holds it (see `LaunchAtLogin`), so
    /// a change is asked of the OS and the toggle then shows what the OS says.
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue, launchAtLogin != LaunchAtLogin.isEnabled else { return }
            do { try LaunchAtLogin.set(launchAtLogin) }
            catch { log("launch at login: \(error.localizedDescription)") }
            let actual = LaunchAtLogin.isEnabled
            if actual != launchAtLogin { launchAtLogin = actual }
        }
    }
    @Published var lanIP: String { didSet { Store.lanIP = lanIP } }
    @Published private(set) var resolution: MirrorResolution
    @Published private(set) var bitrate: MirrorBitrate
    @Published private(set) var frameRate: MirrorFrameRate
    /// Route the phone's audio to this Mac (`no_audio=false`). While it streams, the
    /// phone mutes its own speaker — so this is "where does the sound come out",
    /// not "is there sound".
    @Published private(set) var audioEnabled: Bool
    /// Mac-side mute: the phone keeps streaming, this Mac just stays silent.
    /// Session-only (see `setAudioMuted`).
    @Published private(set) var audioMuted = false
    @Published private(set) var lastDevice: DeviceRef?
    /// The remembered-device roster (device-centric; most-recent first).
    @Published private(set) var knownDevices: [KnownDevice]
    /// Id of the currently connected device (nil when disconnected). Set provisionally
    /// on connect, confirmed once `/base-info` returns the real id.
    @Published private(set) var activeDeviceId: String?

    // Phones on the vivo account (account mode only). The connection centre
    // lists every phone signed into the account with the LAN address it last
    // reported, so the menu can offer them for a one-click Wi-Fi connect.
    /// Account mode with a signed-in account — the menu shows the section.
    @Published private(set) var cloudAccountActive = false
    /// Serverless mode — the menu offers the manual ways in (QR / USB / typed IP).
    @Published private(set) var serverlessMode = Store.connectionMode == .serverless
    /// The phones, as of the last refresh. Empty while signed out.
    @Published private(set) var cloudPhones: [CloudDevice] = []
    /// Polls the list while the account is active — a phone's address changes
    /// whenever it roams, and there is no push channel to tell us (yet).
    private var cloudRefreshTimer: Timer?
    private var cloudRefreshInFlight = false
    private let cloudRefreshInterval: TimeInterval = 60

    /// Account mode: hold a 10191 connection to the phone open so it lists this
    /// Mac as discoverable ("可连"). Toggling re-evaluates the hold.
    @Published var holdPresence: Bool {
        didSet { Store.holdPresence = holdPresence; syncPresenceHold() }
    }
    /// Live presence state for the UI: "", "connecting", "holding", "reconnecting",
    /// "error: …" or "stopped".
    @Published private(set) var presenceStatus: String = ""
    /// The running presence hold (nil = not holding). Dropping it stops the hold.
    private var cloudPresence: PcCloudPresence?
    /// The phone IP the current hold targets, so a roamed address restarts it.
    private var presencePhoneIP: String = ""
    private var presenceStatusTimer: Timer?

    private let controller = SessionController()
    private lazy var mirror = MirrorWindowManager(model: self)

    // Auto-reconnect bookkeeping (main thread). A bumped `reconnectGen` cancels any
    // pending attempt; `reconnectDevice` is non-nil only while a sequence is active.
    private var reconnectGen = 0
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 6
    private var reconnectDevice: DeviceRef?
    /// Consecutive empty USB cable probes in the current wait — only used to slow
    /// the polling down; the wait itself is unbounded.
    private var cablePolls = 0
    /// Why the last attempt of this sequence failed (already user-facing), kept so
    /// giving up can say so. Cleared whenever the sequence parks or restarts.
    private var lastReconnectError: String?

    /// Set by the mirror window: receives the phone's caret position (mirror
    /// pixel space) or nil when no field is focused. Plain closure (not
    /// @Published) so high-frequency caret updates don't churn SwiftUI.
    var imeCursorSink: ((CGPoint?) -> Void)?
    /// Set by the mirror window: whether the phone has a focused text field, so
    /// the keyboard only types in input mode.
    var imeActiveSink: ((Bool) -> Void)?
    /// Set by the mirror window: live playback stats `(fps, pipelineLatencyMs)` for
    /// the HUD (latency is the PC pipeline cost, not glass-to-glass). A plain closure
    /// rather than `@Published` for the same reason as the caret above, and here it's
    /// load-bearing: these tick every second while mirroring, and anything published
    /// on the model rebuilds the menu-bar dropdown — which closes whatever submenu
    /// the pointer is in, making the menu impossible to use during a mirror.
    var mirrorStatsSink: ((Double, Double) -> Void)?

    init() {
        autoReconnect = Store.autoReconnect
        holdPresence = Store.holdPresence
        clipboardEnabled = Store.clipboardEnabled
        clipboardDirection = Store.clipboardDirection
        verifyEnabled = Store.verifyEnabled
        notifyEnabled = Store.notifyEnabled
        showStats = Store.showStats
        launchAtLogin = LaunchAtLogin.isEnabled
        lanIP = Store.lanIP
        resolution = Store.resolution
        bitrate = Store.bitrate
        frameRate = Store.frameRate
        audioEnabled = Store.mirrorAudio
        lastDevice = Store.lastDevice
        knownDevices = Store.knownDevices
        wire()
        // The account panel owns sign-in / mode; it tells us when either changes
        // so the phone list starts, stops, or refreshes accordingly.
        NotificationCenter.default.addObserver(
            forName: .vivoAccountDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.syncCloudPhoneWatch() }
        syncCloudPhoneWatch()
        if autoReconnect, let dev = lastDevice {
            // Same sequence as a mid-session drop rather than a single shot: at
            // login the phone may not be plugged in yet and Wi-Fi may not be up,
            // and neither is worth greeting the user with a failure banner.
            beginReconnect(to: dev, delay: 0)
        }
        if ["1", "2", "3", "4", "5"].contains(ProcessInfo.processInfo.environment["PCSUITE_MIRROR_TEST"]) {
            DispatchQueue.main.async { [weak self] in self?.openMirrorTest() }
        }
        // Dev aid: open the settings window at launch (nothing in the menu bar
        // can be driven from a shell), on the tab named by the value if any.
        if let want = ProcessInfo.processInfo.environment["PCSUITE_OPEN_SETTINGS"] {
            let tab = PreferencesTab.allCases.first { "\($0)" == want }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                PreferencesWindowController.shared.show(model: self, tab: tab)
            }
        }
    }

    // MARK: - Derived state for the UI

    var isConnected: Bool { if case .connected = state { return true }; return false }
    /// A connect the *user* asked for is in flight — the menu collapses to just
    /// "Cancel" while it runs. Auto-reconnect deliberately doesn't count: it is
    /// background work that can last minutes (or, on a USB cable watch, forever),
    /// and locking the menu for its duration would strand the user with no way to
    /// reach the other transports.
    var isBusy: Bool {
        if case .connecting = state { return true }; return false
    }
    /// An auto-reconnect attempt is in flight.
    var isReconnecting: Bool {
        if case .reconnecting = state { return true }; return false
    }
    /// Parked on the USB cable watch: no phone plugged in, retrying quietly.
    var isWaitingForPhone: Bool {
        if case .waitingForPhone = state { return true }; return false
    }
    var busyDevice: DeviceRef? {
        switch state {
        case .connecting(let d), .reconnecting(let d): return d
        default: return nil
        }
    }
    var statusText: String {
        switch state {
        case .disconnected: return L("Disconnected")
        case .connecting(let d): return "\(L("Connecting…")) \(d.displayName)"
        case .reconnecting(let d): return "\(L("Reconnecting…")) \(d.displayName)"
        case .waitingForPhone: return L("Waiting for a phone over USB…")
        case .connected(let d): return "\(L("Connected")) · \(d.displayName)"
        case .failed(let m): return "\(L("Connection failed")): \(m)"
        }
    }
    var statusIcon: String {
        switch state {
        case .connected: return "checkmark.circle.fill"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .disconnected, .waitingForPhone: return "circle.dashed"
        }
    }
    /// SF Symbol for the menu-bar icon — the only always-visible surface of a
    /// menu-bar agent — so connection state reads at a glance without opening it.
    /// Keeps the phone motif for the two "phone present / absent" states.
    /// Waiting for a cable shows the same idle icon as "disconnected": nothing is
    /// plugged in and nothing is happening, so a permanently spinning menu-bar
    /// glyph would overstate it.
    var menuBarSymbol: String {
        switch state {
        case .connected: return "iphone"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .disconnected, .waitingForPhone: return "iphone.slash"
        }
    }

    private var features: ConnectFeatures {
        ConnectFeatures(
            clipboard: clipboardEnabled,
            clipRecv: clipboardDirection.recv,
            clipSend: clipboardDirection.send,
            verify: verifyEnabled,
            notify: notifyEnabled
        )
    }

    /// Push the current clipboard enable/direction to a live session (no-op when
    /// disconnected; the next connect applies it via `features`).
    private func applyClipboardLive() {
        guard isConnected else { return }
        controller.setClipboard(enabled: clipboardEnabled,
                                recv: clipboardDirection.recv,
                                send: clipboardDirection.send)
    }

    // MARK: - Intents

    func connectUSB() {
        cancelReconnect()
        controller.connect(DeviceRef(transport: .usb, ip: nil), features: features, reconnect: false)
    }

    func connectLAN() {
        let ip = lanIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else { return }
        cancelReconnect()
        controller.connect(DeviceRef(transport: .lan, ip: ip), features: features, reconnect: false)
    }

    // MARK: - Phones on the vivo account

    /// Connect over Wi-Fi to a phone from the account list, at the address it
    /// last reported to the connection centre.
    func connectCloud(_ phone: CloudDevice) {
        guard !phone.ip.isEmpty else { return }
        cancelReconnect()
        controller.connect(DeviceRef(transport: .lan, ip: phone.ip, name: phone.name),
                           features: features, reconnect: false)
    }

    /// Start, stop, or restart the phone-list poll to match the account state.
    /// Call whenever the mode or sign-in changes; harmless to call again.
    private func syncCloudPhoneWatch() {
        let active = Store.connectionMode == .vivoAccount && VivoAccount.isSignedIn
        cloudRefreshTimer?.invalidate()
        cloudRefreshTimer = nil
        serverlessMode = Store.connectionMode == .serverless
        cloudAccountActive = active
        guard active else {
            if !cloudPhones.isEmpty { cloudPhones = [] }
            syncPresenceHold()   // signed out → drop any hold
            return
        }
        refreshCloudPhones()
        // Default run-loop mode on purpose: the timer then waits while the menu
        // is open rather than rebuilding it under the pointer.
        cloudRefreshTimer = Timer.scheduledTimer(withTimeInterval: cloudRefreshInterval, repeats: true) {
            [weak self] _ in self?.refreshCloudPhones()
        }
    }

    /// Fetch `/device/list` off the main thread and publish the phones — but only
    /// when something the menu shows (id, name, address) actually changed:
    /// publishing rebuilds the dropdown, which closes any submenu the pointer is
    /// in, and `reportTime` alone moves every time the phone checks in.
    func refreshCloudPhones() {
        guard cloudAccountActive, !cloudRefreshInFlight else { return }
        cloudRefreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var phones: [CloudDevice]?
            do {
                // At launch this can run before the app delegate has handed the
                // core its mode + account (the model is built when the scene is);
                // the core refuses cloud calls until then. Cheap, so do it here.
                applyAccountToCore()
                let raw = try pcsuite_cloud_devices().toString()
                phones = raw.components(separatedBy: "\n").compactMap(CloudDevice.parse).filter(\.isPhone)
            } catch {
                log("account phone list: \(ffiMessage(error))")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.cloudRefreshInFlight = false
                guard self.cloudAccountActive, let phones else { return }
                let key = { (p: CloudDevice) in [p.id, p.name, p.ip] }
                if phones.map(key) != self.cloudPhones.map(key) {
                    self.cloudPhones = phones
                    log("account phone list: \(phones.map { "\($0.name)@\($0.ip)" }.joined(separator: ", "))")
                }
                // (Re)hold presence to the account phone; a roamed IP restarts it.
                self.syncPresenceHold()
            }
        }
    }

    // MARK: - Presence hold (account mode「可连」)

    /// Reconcile the presence hold with the current state: hold a 10191 connection
    /// to the account phone while signed in + `holdPresence`, drop it otherwise,
    /// and restart it when the phone's IP changes.
    private func syncPresenceHold() {
        // Presence and a live session both do a 10191 ConnectFlow to the phone,
        // which only accepts one connection per PC — so they fight (the phone
        // closes one, control WS to 10380 gets refused). Hold presence ONLY while
        // idle; a real connect takes over, and disconnecting resumes presence.
        let sessionActive: Bool = {
            switch state {
            case .disconnected, .failed: return false
            default: return true
            }
        }()
        let wanted = cloudAccountActive && holdPresence && !sessionActive
        let ip = cloudPhones.first(where: { !$0.ip.isEmpty })?.ip ?? ""
        guard wanted, !ip.isEmpty else {
            if cloudPresence != nil { stopPresenceHold() }
            return
        }
        if cloudPresence != nil && ip == presencePhoneIP { return }  // already holding this IP
        startPresenceHold(ip: ip)
    }

    private func startPresenceHold(ip: String) {
        stopPresenceHold()
        applyAccountToCore()        // ensure the core has the account before it fetches the seed
        applyIdentityToCore()       // ensure a real businessId (target_id) is set
        presencePhoneIP = ip
        presenceStatus = "connecting"
        cloudPresence = pcsuite_cloud_presence_start(ip, false)
        log("presence hold: → \(ip)")
        // Poll the Rust-side status for the UI (cheap lock read).
        presenceStatusTimer?.invalidate()
        presenceStatusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let p = self.cloudPresence else { return }
            let s = p.status().toString()
            if s != self.presenceStatus { self.presenceStatus = s }
            // The phone tapped 「连接」 → establish the session (connect only; the
            // mirror window stays user-initiated, matching the phone's semantics).
            if p.take_connect_request() { self.handlePhoneConnectRequest() }
        }
    }

    /// React to the phone tapping 「连接」 while we hold presence: open the control
    /// session to it (no mirror). No-op if a session is already up.
    private func handlePhoneConnectRequest() {
        guard !isConnected, !presencePhoneIP.isEmpty else { return }
        let ip = presencePhoneIP
        log("presence: 手机请求连接 → 建立会话 \(ip)")
        let name = cloudPhones.first(where: { $0.ip == ip })?.name ?? L("Phone")
        // Stop holding presence first: presence + a live connect both open a 10191
        // ConnectFlow and the phone allows only one, so they'd knock each other's
        // 10380 session out. The connect takes over; disconnecting resumes presence.
        stopPresenceHold()
        cancelReconnect()   // drop any stale auto-reconnect (e.g. to an old-network IP)
        controller.connect(DeviceRef(transport: .lan, ip: ip, name: name),
                           features: features, reconnect: false)
    }

    private func stopPresenceHold() {
        presenceStatusTimer?.invalidate()
        presenceStatusTimer = nil
        cloudPresence?.stop()
        cloudPresence = nil
        presencePhoneIP = ""
        if !presenceStatus.isEmpty { presenceStatus = "" }
    }

    /// Connect a remembered device over the chosen transport. Wi-Fi uses the
    /// device's last-known IP; USB connects to whatever phone is on the cable.
    func connect(_ device: KnownDevice, method: Transport) {
        cancelReconnect()
        let ref: DeviceRef
        switch method {
        case .usb: ref = DeviceRef(transport: .usb, ip: nil, name: device.name)
        case .lan: ref = DeviceRef(transport: .lan, ip: device.lastIP, name: device.name)
        }
        controller.connect(ref, features: features, reconnect: false)
    }

    /// Drop a device from the roster (and the auto-reconnect target if it was this one).
    func forget(_ device: KnownDevice) {
        knownDevices.removeAll { $0.id == device.id }
        Store.knownDevices = knownDevices
        if let last = lastDevice, device.matches(last) {
            lastDevice = nil
            Store.lastDevice = nil
        }
        if activeDeviceId == device.id { activeDeviceId = nil }
    }

    /// QR pairing (local `ls=true`): show a QR for the phone to scan; on scan the
    /// phone reports its IP and we connect — no IP/openID/seed needed.
    func pairQR() {
        cancelReconnect()
        controller.pairAndConnect(features: features) { url in
            QRPairingWindowController.shared.show(url: url) { [weak self] in
                self?.cancelConnect()
            }
        }
    }

    func cancelConnect() { cancelReconnect(); controller.cancel() }
    func disconnect() { cancelReconnect(); closeMirror(); controller.disconnect() }

    /// Start over as if freshly installed: drop the session, sign out of the vivo
    /// account, forget every phone and the LAN identity, and put every option
    /// back to its default — in the store, in the core, and in this model. The
    /// app keeps running.
    func resetAllSettings() {
        disconnect()
        // `disconnect()` reports .disconnected only once the session is really
        // gone; move there now so nothing below (a toggle's live-apply, a late
        // /base-info) mistakes the dying session for a live one.
        state = .disconnected
        // The core holds the seeds it was handed as overrides; hand back empties
        // so no part of the old identity outlives the store.
        for e in Store.seeds {
            pcsuite_set_seed(e.ip.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        VivoAccount.signOut()
        Store.resetAll()
        applyIdentityToCore()
        syncCloudPhoneWatch()          // signed out now → stops the poll, clears the list
        // Restart the LAN beacon: it snapshots the identity when it starts.
        do { try pcsuite_presence_start() } catch { log("presence: \(ffiMessage(error))") }
        // The settings window's Identity / Account tabs snapshot the store when
        // built; drop the window so the next open reads the fresh values.
        PreferencesWindowController.shared.discard()
        QRPairingWindowController.shared.close()
        // Re-read every published value. Each didSet writes the default back
        // to the store, which is fine, and none applies live — nothing is connected.
        autoReconnect = Store.autoReconnect
        clipboardEnabled = Store.clipboardEnabled
        clipboardDirection = Store.clipboardDirection
        verifyEnabled = Store.verifyEnabled
        notifyEnabled = Store.notifyEnabled
        showStats = Store.showStats
        launchAtLogin = false          // held by the OS, not the store; off is the default
        lanIP = Store.lanIP
        resolution = Store.resolution
        bitrate = Store.bitrate
        frameRate = Store.frameRate
        audioEnabled = Store.mirrorAudio
        audioMuted = false
        lastDevice = nil
        knownDevices = []
        activeDeviceId = nil
        deviceInfo = nil
        fileTransferNote = nil
        log("all settings reset")
    }

    // MARK: - File transfer

    /// Send local files to the phone (dropped onto the mirror window or picked
    /// from the menu). No-op when disconnected.
    func pushFiles(_ urls: [URL]) {
        guard isConnected else { return }
        noteFileTransfer(String(format: L("Sending %lld file(s)…"), urls.count), sticky: true)
        controller.pushFiles(urls)
    }

    /// Show a file-transfer status line; auto-clears after a few seconds unless
    /// `sticky` (a terminal event replaces a sticky note and re-arms the timer).
    private var noteGen = 0
    private func noteFileTransfer(_ text: String, sticky: Bool = false) {
        noteGen += 1
        let gen = noteGen
        fileTransferNote = text
        guard !sticky else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.noteGen == gen else { return }
            self.fileTransferNote = nil
        }
    }

    // MARK: - Auto-reconnect on unexpected loss

    /// An established session ended on its own. A dropped link (USB unplug, Wi-Fi
    /// loss) starts the bounded reconnect sequence when auto-reconnect is on. A
    /// session the phone ended on purpose does not: the user disconnected there,
    /// and dialling straight back in would undo what they just did — they can
    /// reconnect from the menu (or the phone) when they mean to.
    private func handleConnectionLost(_ device: DeviceRef, phoneEnded: Bool) {
        if phoneEnded { log("phone ended the session — not reconnecting") }
        guard autoReconnect, !phoneEnded else {
            mirrorLink = mirror.isShowing ? .lost : .live
            return
        }
        beginReconnect(to: device, delay: 0.5)
    }

    /// Start (or restart) an auto-reconnect sequence toward `device`.
    private func beginReconnect(to device: DeviceRef, delay: TimeInterval) {
        reconnectGen += 1
        reconnectAttempts = 0
        cablePolls = 0
        lastReconnectError = nil
        reconnectDevice = device
        mirrorLink = mirror.isShowing ? .reconnecting : .live
        scheduleReconnect(gen: reconnectGen, delay: delay)
    }

    /// Fire one reconnect attempt after `delay`, unless the sequence was cancelled
    /// or auto-reconnect was turned off in the meantime.
    ///
    /// USB goes through the cable probe first. Running a connect against a phone
    /// that isn't plugged in only produces an adb diagnostic ("no adb device in
    /// 'device' state — …"), which is developer text for a situation that isn't
    /// even an error: the user unplugged the cable. So we ask adb cheaply instead,
    /// and when there's nothing there we simply keep watching — quietly, and
    /// without spending the retry budget.
    private func scheduleReconnect(gen: Int, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.reconnectGen == gen, self.autoReconnect,
                  let dev = self.reconnectDevice else { return }
            guard dev.transport == .usb else { self.fireReconnect(gen: gen, device: dev); return }
            self.controller.probeUSB { [weak self] link in
                guard let self, self.reconnectGen == gen, self.autoReconnect,
                      self.reconnectDevice != nil else { return }
                switch link {
                case .ready:
                    self.cablePolls = 0
                    // A phone *is* on the cable and it still won't connect — that
                    // is a real failure, unlike a missing cable, so the budget
                    // applies here and only here.
                    guard self.reconnectAttempts < self.maxReconnectAttempts else {
                        self.giveUpReconnect(status: self.retriesExhausted(dev), reason: self.lastReconnectError)
                        return
                    }
                    self.fireReconnect(gen: gen, device: dev)
                case .noDevice, .unauthorized:
                    self.parkOnCable(gen: gen, device: dev, link: link)
                case .noAdb:
                    // No adb binary: USB can never come up, so waiting is pointless.
                    log("USB: adb is unusable — ending the reconnect wait")
                    self.giveUpReconnect(status: L("adb not found — install Android platform-tools to connect over USB"))
                }
            }
        }
    }

    private func fireReconnect(gen: Int, device: DeviceRef) {
        reconnectAttempts += 1
        var dev = device
        // In account mode the remembered LAN IP goes stale when the phone roams to
        // another network. Prefer the current address the account device list
        // reports for the same phone before dialing the old one.
        if dev.transport == .lan, cloudAccountActive, let name = device.name,
           let cur = cloudPhones.first(where: { $0.name == name && !$0.ip.isEmpty }),
           cur.ip != device.ip {
            log("auto-reconnect: 设备列表新地址 \(cur.ip)(旧 \(device.ip ?? "?"))")
            dev = DeviceRef(transport: .lan, ip: cur.ip, name: name)
            reconnectDevice = dev   // keep dialing the fresh IP on later attempts
        }
        log("auto-reconnect attempt \(reconnectAttempts)/\(maxReconnectAttempts) → \(dev.displayName)")
        controller.connect(dev, features: features, reconnect: true)
    }

    /// No phone on the cable (or one that hasn't authorized debugging yet). Show a
    /// plain "waiting" status, hand the retry budget back — the next cable is a
    /// fresh start — and look again shortly. Unbounded on purpose: an unplugged
    /// cable stays unplugged until the user does something about it.
    private func parkOnCable(gen: Int, device: DeviceRef, link: USBLink) {
        if cablePolls == 0 {
            log(link == .unauthorized
                ? "USB: phone attached but debugging isn't authorized — waiting"
                : "USB: no phone on the cable — waiting")
        }
        cablePolls += 1
        reconnectAttempts = 0
        lastReconnectError = nil
        state = .waitingForPhone(device)
        // Quick at first so a fast replug is caught immediately, then settle down:
        // each poll spawns an `adb devices`, and this loop can run for hours.
        scheduleReconnect(gen: gen, delay: cablePolls < 8 ? 2 : 6)
    }

    /// End the sequence. `status` (short, user-facing) is shown as the failure
    /// status for a few seconds; nil ends it silently. `reason` — the last
    /// attempt's error — only goes to the log: a core failure is a whole context
    /// chain on one line, and after a drop the user already knows the phone is
    /// gone; they don't need the transport's account of it in a menu label.
    private func giveUpReconnect(status: String?, reason: String? = nil) {
        if status != nil || reason != nil {
            log("auto-reconnect gave up: \(reason ?? status ?? "")")
        }
        let showing = mirror.isShowing
        cancelReconnect()
        mirrorLink = showing ? .lost : .live
        if let status {
            state = .failed(status)
            scheduleFailedReset()
        }
    }

    /// The status shown when the retry budget runs out, whatever the last error was.
    private func retriesExhausted(_ device: DeviceRef) -> String {
        String(format: L("couldn't reach %@ after several attempts"), device.displayName)
    }

    /// Turn a raw core failure into something worth showing a person.
    ///
    /// The USB path's adb diagnostics are developer text — they name adb states and
    /// paste `adb devices` output — and they're the failures users hit most, since
    /// "the cable isn't in" is an everyday situation. Anything else is passed
    /// through, minus any trailing detail lines: this ends up in a menu label and a
    /// notification body, neither of which can show a multi-line dump.
    private func friendlyConnectError(_ raw: String) -> String {
        if raw.contains("no adb device") {
            return L("No phone over USB — plug in the cable and allow USB debugging on the phone")
        }
        if raw.contains("adb") && (raw.contains("spawn") || raw.contains("No such file")) {
            return L("adb not found — install Android platform-tools to connect over USB")
        }
        if raw.contains("/version never returned") {
            return L("The phone didn't answer over USB — unlock it, keep the screen on, and try again")
        }
        return raw.components(separatedBy: "\n").first ?? raw
    }

    // Auto-clears a stuck `.failed` status back to `.disconnected`. Bumped on each
    // failure so a later connect attempt (which moves state off `.failed`) wins.
    private var failedResetGen = 0

    /// After a user-initiated connect failure, revert the menu status to
    /// `Disconnected` shortly after — unless a new attempt already changed state.
    private func scheduleFailedReset() {
        failedResetGen += 1
        let gen = failedResetGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.failedResetGen == gen, case .failed = self.state else { return }
            self.state = .disconnected
        }
    }

    /// Stop any in-flight reconnect sequence and clear the overlay.
    private func cancelReconnect() {
        reconnectGen += 1
        reconnectAttempts = 0
        cablePolls = 0
        reconnectDevice = nil
        lastReconnectError = nil
        mirrorLink = .live
        // The cable watch is the one state that would otherwise outlive its
        // sequence: nothing else will move it off "waiting".
        if isWaitingForPhone { state = .disconnected }
    }
    /// The current resolution/bitrate/fps/audio choices, resolved for the core.
    var mirrorSettings: MirrorSettings {
        MirrorSettings(maxSize: resolution.maxSize, bitRate: bitrate.bps,
                       frameRate: frameRate.fps, audio: audioEnabled)
    }
    func startMirror() { controller.startMirror(settings: mirrorSettings) }
    func stopMirror() { controller.stopMirror() }

    /// Upsert the just-connected device into the roster, keyed by its stable device
    /// id (from `/base-info`). Records the name + (for Wi-Fi) the IP so the next
    /// connect can offer it. Most-recently-connected sorts first.
    private func rememberConnectedDevice(_ info: PhoneInfo) {
        guard !info.deviceId.isEmpty else { return }
        activeDeviceId = info.deviceId
        var dev = knownDevices.first { $0.id == info.deviceId }
            ?? KnownDevice(id: info.deviceId, name: info.name, lastIP: nil, lastTransport: nil)
        if !info.name.isEmpty { dev.name = info.name }
        if let ref = lastDevice {
            dev.lastTransport = ref.transport
            if ref.transport == .lan, let ip = ref.ip, !ip.isEmpty { dev.lastIP = ip }
        }
        knownDevices.removeAll { $0.id == dev.id }
        knownDevices.insert(dev, at: 0)
        Store.knownDevices = knownDevices
        log("roster upsert: \(dev.name) [\(dev.id)] → \(knownDevices.count) device(s)")
    }

    /// Which preset the current knobs correspond to, or `.custom` if none.
    var currentPreset: MirrorPreset {
        for p in MirrorPreset.allCases {
            if let t = p.triple, t.0 == resolution, t.1 == bitrate, t.2 == frameRate { return p }
        }
        return .custom
    }

    /// Apply a one-tap preset (sets resolution + bitrate + frame rate together);
    /// restarts the live stream if mirroring. `.custom` is a no-op.
    func applyPreset(_ p: MirrorPreset) {
        guard let t = p.triple else { return }
        resolution = t.0; Store.resolution = t.0
        bitrate = t.1; Store.bitrate = t.1
        frameRate = t.2; Store.frameRate = t.2
        if mirroring { controller.restartMirror(settings: mirrorSettings) }
    }

    /// Change mirror resolution; restarts the live stream if mirroring.
    func setResolution(_ r: MirrorResolution) {
        guard r != resolution else { return }
        resolution = r
        Store.resolution = r
        if mirroring { controller.restartMirror(settings: mirrorSettings) }
    }

    /// Change mirror bitrate; restarts the live stream if mirroring.
    func setBitrate(_ b: MirrorBitrate) {
        guard b != bitrate else { return }
        bitrate = b
        Store.bitrate = b
        if mirroring { controller.restartMirror(settings: mirrorSettings) }
    }

    /// Change mirror frame rate; restarts the live stream if mirroring.
    func setFrameRate(_ f: MirrorFrameRate) {
        guard f != frameRate else { return }
        frameRate = f
        Store.frameRate = f
        if mirroring { controller.restartMirror(settings: mirrorSettings) }
    }

    /// Route the phone's audio to this Mac (on) or leave it on the phone (off).
    ///
    /// Applied to a live mirror without restarting it — the phone accepts the switch
    /// on the control channel — so toggling this never interrupts the picture.
    /// `SCREEN_START` carries the same choice for the next stream.
    func setAudio(_ on: Bool) {
        guard on != audioEnabled else { return }
        audioEnabled = on
        Store.mirrorAudio = on
        controller.setAudioToPC(on)
    }

    /// Silence this Mac only: the phone keeps streaming (and stays muted itself), so
    /// nothing plays anywhere until unmuted. Deliberately **not** persisted — an app
    /// that starts up silently for a forgotten reason reads as broken; the durable
    /// "I don't want phone audio here" preference is `audioEnabled` above.
    func setAudioMuted(_ on: Bool) {
        guard on != audioMuted else { return }
        audioMuted = on
        controller.setAudioMuted(on)
    }

    func toggleAudioMuted() { setAudioMuted(!audioMuted) }

    /// Open the mirror window (which begins mirroring) / close it (which stops).
    func openMirror() { mirror.show() }
    func closeMirror() { mirror.close() }

    /// Open a blank mirror window with NO phone connection, for UI testing of the
    /// window/hover chrome. Faked video size drives the aspect layout; the surface shows
    /// its placeholder. Enabled via the PCSUITE_MIRROR_TEST=1 environment variable.
    func openMirrorTest() {
        let mode = ProcessInfo.processInfo.environment["PCSUITE_MIRROR_TEST"]
        if mode == "4" || mode == "5" {
            // Real mirror, once the auto-reconnect has settled. 4 = auto-toggle hover,
            // 5 = stay at rest (for inspecting the un-hovered corners).
            DispatchQueue.main.asyncAfter(deadline: .now() + 11) { [weak self] in
                guard let self else { return }
                self.openMirror()
                if mode == "4" { self.mirror.testAutoToggle() } else { self.mirror.testPosition() }
            }
            return
        }
        videoSize = CGSize(width: 1080, height: 2400)
        mirror.show(connect: false)
        switch mode {
        case "2": mirror.testForceHover()
        case "3": mirror.testAutoToggle()
        default: break
        }
    }

    func mouse(action: UInt8, button: UInt8, x: Int, y: Int, w: Int, h: Int) {
        controller.sendMouse(action: action, button: button, x: x, y: y, w: w, h: h)
    }
    func scroll(v: Int, x: Int, y: Int, w: Int, h: Int) {
        controller.sendScroll(v: v, x: x, y: y, w: w, h: h)
    }
    /// Press an Android navigation key (see `AndroidKey`).
    func key(_ keycode: Int) { controller.sendKey(keycode) }
    /// Type Unicode text into the phone's focused field.
    func typeText(_ s: String) { controller.sendText(s) }
    /// Backspace (delete one char before the cursor).
    func backspace() { controller.sendDeleteSurrounding(before: 1, after: 0) }

    /// Whether the phone is currently showing a secure/privacy screen.
    var privacyActive: Bool { !privacyState.isEmpty && privacyState != "clear" }

    // MARK: - Controller wiring (callbacks arrive on main)

    private func wire() {
        controller.onState = { [weak self] st in
            guard let self else { return }
            var st = st
            // Sanitize once, up front: nothing below (menu status, notification,
            // give-up message) should ever see the raw core/adb text.
            if case .failed(let raw) = st { st = .failed(self.friendlyConnectError(raw)) }
            // A failure inside a reconnect sequence isn't a UI event — the next
            // attempt is already scheduled. Holding on "reconnecting" avoids a
            // flash of the error text and the warning icon between attempts.
            if case .failed = st, let dev = self.reconnectDevice {
                self.state = .reconnecting(dev)
            } else {
                self.state = st
            }
            // The QR pairing window only exists while waiting for a scan; dismiss it
            // once we leave that wait (connected / failed / disconnected).
            switch st {
            case .connecting, .reconnecting: break
            default: QRPairingWindowController.shared.close()
            }
            switch st {
            case .connected(let d):
                self.syncPresenceHold()   // live session owns the link → drop presence
                self.lastDevice = d
                Store.lastDevice = d
                // Highlight the matching roster entry right away; `/base-info` will
                // confirm/correct the id shortly via rememberConnectedDevice.
                self.activeDeviceId = self.knownDevices.first { $0.matches(d) }?.id
                if self.reconnectDevice != nil { log("auto-reconnect succeeded") }
                self.cancelReconnect()
                // Resume mirroring if the window is still open after a recovered drop.
                if self.mirror.isShowing && !self.mirroring {
                    self.controller.startMirror(settings: self.mirrorSettings)
                }
            case .disconnected:
                self.deviceInfo = nil
                self.activeDeviceId = nil
                self.fileTransferNote = nil
                self.syncPresenceHold()   // idle again → resume presence (可连)
            case .failed(let message):
                // A reconnect attempt failed: back off and retry, or give up.
                guard let dev = self.reconnectDevice else {
                    // User-initiated connect failed. The dropdown may be closed, so
                    // surface the reason as a notification, and don't leave the menu
                    // status stuck on "failed" forever.
                    Notifier.postConnectFailure(message)
                    self.scheduleFailedReset()
                    break
                }
                self.lastReconnectError = message
                let backoff = min(8.0, pow(2.0, Double(max(1, self.reconnectAttempts) - 1)))
                // Auto-reconnect was switched off under a running attempt: the
                // user ended this themselves, so there's nothing to announce.
                guard self.autoReconnect else { self.giveUpReconnect(status: nil, reason: message); break }
                // USB skips the budget check here: whether this failure even counts
                // depends on the cable, and only the probe in scheduleReconnect
                // knows that. Everything else gives up once the budget is spent.
                if dev.transport == .usb || self.reconnectAttempts < self.maxReconnectAttempts {
                    log("auto-reconnect retry in \(Int(backoff))s (\(message))")
                    self.scheduleReconnect(gen: self.reconnectGen, delay: backoff)
                } else {
                    self.giveUpReconnect(status: self.retriesExhausted(dev), reason: message)
                }
            default:
                break
            }
        }
        controller.onConnectionLost = { [weak self] device, phoneEnded in
            self?.handleConnectionLost(device, phoneEnded: phoneEnded)
        }
        controller.onMirroring = { [weak self] on, layer in
            guard let self else { return }
            self.mirroring = on
            self.displayLayer = layer
            if !on {
                self.videoSize = .zero; self.privacyState = ""; self.screenLocked = false
                self.mirrorStatsSink?(0, 0)
            }
        }
        controller.onStats = { [weak self] fps, lat in
            self?.mirrorStatsSink?(fps, lat)
        }
        controller.onPrivacy = { [weak self] tok in self?.privacyState = tok }
        controller.onLock = { [weak self] locked in self?.screenLocked = locked }
        controller.onInputState = { [weak self] active, hasCaret, x, y in
            guard let self else { return }
            self.imeActiveSink?(active)        // gate the keyboard on input mode
            if !active {
                self.imeCursorSink?(nil)       // field gone → fall back to pointer
            } else if hasCaret {
                self.imeCursorSink?(CGPoint(x: x, y: y))
            }
        }
        controller.onFormat = { [weak self] w, h in
            self?.videoSize = CGSize(width: w, height: h)
        }
        controller.onVerifyCode = { [weak self] code in
            self?.lastCode = code
            Pasteboard.copy(code)
            Notifier.postCode(code)
        }
        controller.onNotification = { app, title, content in
            Notifier.postPhoneNotification(app: app, title: title, body: content)
        }
        controller.onPushResult = { [weak self] dir, error in
            guard let self else { return }
            if let dir {
                self.noteFileTransfer(String(format: L("Sent → %@"), dir))
            } else if let error {
                self.noteFileTransfer(String(format: L("Send failed: %@"), error))
                Notifier.postFileSendFailed(error)
            }
        }
        controller.onFileTransfer = { [weak self] type, files, dir, error in
            guard let self else { return }
            switch type {
            case "started":
                // 互传 (EasyShare) 批次在 10191 connect 帧时 started，文件名未知
                // （files 为空）；快传批次 files 至少一个。
                if files.isEmpty {
                    self.noteFileTransfer(L("Receiving via EasyShare…"), sticky: true)
                } else {
                    self.noteFileTransfer(String(format: L("Receiving %lld file(s)…"), files.count), sticky: true)
                }
            case "done":
                self.noteFileTransfer(String(format: L("Received %lld file(s) → %@"), files.count, dir))
                Notifier.postFilesReceived(count: files.count, dir: dir)
            case "failed":
                self.noteFileTransfer(String(format: L("Receive failed: %@"), error))
                Notifier.postFileReceiveFailed(error)
            case "cancelled":
                self.noteFileTransfer(L("Transfer cancelled by phone"))
            default:
                break
            }
        }
        controller.onDeviceInfo = { [weak self] info in
            // The fetch isn't generation-guarded: one that lands after a reset
            // would write the old phone (and openID) straight back into the store.
            guard let self, self.isConnected else { return }
            self.deviceInfo = info
            self.autoFillOpenID(info.openID)
            self.rememberConnectedDevice(info)
        }
    }

    /// The phone reports its real account openID in `/base-info`. A session that
    /// connected without one configured (notably QR pairing, whose local path never
    /// carries openID) can learn it here and save it — so the account-scoped features
    /// (clipboard) and connectType=1 reconnect work on the next connect. Only fills an
    /// empty slot; never clobbers a value the user set by hand.
    private func autoFillOpenID(_ raw: String) {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id != Store.openID else { return }
        if Store.openID.isEmpty {
            Store.openID = id
            applyIdentityToCore()   // push into the core for subsequent connects
            log("learned account openID from phone; saved (clipboard + reconnect now configured)")
        } else {
            log("phone openID differs from the configured one; keeping yours")
        }
    }
}
