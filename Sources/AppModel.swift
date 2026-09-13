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
    @Published private(set) var state: ConnState = .disconnected {
        didSet {
            switch state {
            case .failed(let m):
                lastFailure = ConnectFailure(shown: m, detail: failureDetail)
                connectPhase = nil
            case .connecting, .reconnecting:
                // A new attempt (or a working session) is what makes an old
                // failure stale — not the status line reverting to Disconnected.
                lastFailure = nil
                failureDetail = nil
            case .connected:
                lastFailure = nil
                failureDetail = nil
                connectPhase = nil
            case .disconnected:
                connectPhase = nil
            default: break
            }
        }
    }
    /// The most recent connect failure, kept past the status line's reset so it
    /// can still be copied from the menu. nil once a new attempt starts.
    @Published private(set) var lastFailure: ConnectFailure?
    /// What the core actually said for the failure about to be shown (the menu
    /// line is often a friendlier rewrite); picked up by `state`'s didSet.
    private var failureDetail: String?
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
    /// How many times auto-reconnect tries before giving up (1…10, default 1).
    /// Read live by `maxReconnectAttempts`; a change mid-sequence takes effect on
    /// the next attempt. Distinct from the private `reconnectAttempts` counter.
    @Published var reconnectLimit: Int { didSet { Store.reconnectAttempts = reconnectLimit } }
    // Feature toggles apply to a live session immediately (no reconnect needed);
    // didSet only fires on user changes, never during init.
    @Published var clipboardEnabled: Bool { didSet { Store.clipboardEnabled = clipboardEnabled; applyClipboardLive() } }
    @Published var clipboardDirection: ClipboardDirection { didSet { Store.clipboardDirection = clipboardDirection; applyClipboardLive() } }
    @Published var verifyEnabled: Bool { didSet { Store.verifyEnabled = verifyEnabled; if isConnected { controller.setVerify(enabled: verifyEnabled) } } }
    @Published var notifyEnabled: Bool { didSet { Store.notifyEnabled = notifyEnabled; if isConnected { controller.setNotify(enabled: notifyEnabled) } } }
    // Which of this Mac's own banners to show (see `Notifier`). Read at the moment
    // an event lands, so a change applies to the next one straight away.
    @Published var notifyOnConnect: Bool { didSet { Store.notifyOnConnect = notifyOnConnect } }
    @Published var notifyOnFileTransfer: Bool { didSet { Store.notifyOnFileTransfer = notifyOnFileTransfer } }
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
    /// This session rides the held 10191 connection — either the phone asked for it, or
    /// we upgraded the hold ourselves — so presence must keep holding it while it lives
    /// (see `syncPresenceHold`) and must be told when it ends.
    private var sessionRidesPresence = false
    /// The phone is still waiting for the outcome of the connect it asked for.
    private var phoneAskAwaitingReport = false

    private let controller = SessionController()
    private lazy var mirror = MirrorWindowManager(model: self)

    // Auto-reconnect bookkeeping (main thread). A bumped `reconnectGen` cancels any
    // pending attempt; `reconnectDevice` is non-nil only while a sequence is active.
    private var reconnectGen = 0
    private var reconnectAttempts = 0
    /// How many attempts before giving up — the user's 重连次数 setting (default 1).
    private var maxReconnectAttempts: Int { reconnectLimit }
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
        reconnectLimit = Store.reconnectAttempts
        holdPresence = Store.holdPresence
        clipboardEnabled = Store.clipboardEnabled
        clipboardDirection = Store.clipboardDirection
        verifyEnabled = Store.verifyEnabled
        notifyEnabled = Store.notifyEnabled
        notifyOnConnect = Store.notifyOnConnect
        notifyOnFileTransfer = Store.notifyOnFileTransfer
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
        // 互传「我的设备」→ this Mac works only while something listens on :10191,
        // session or not — arm it for the app's lifetime (after wire(), so its
        // events reach onFileTransfer).
        controller.startShareReceiver()
        // 云传输 (cloud transfer): files the phone uploaded to vivo's relay. No
        // socket of its own — it polls, and does nothing at all unless the user
        // is in account mode and signed in, so arming it here is unconditional.
        controller.startCloudReceiver()
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
    /// What an auto-connect is doing while it has no route to name yet —
    /// checking the cable, then asking 10191 which address answers. Shown in
    /// place of the route on the status line; nil once a leg is under way and
    /// the connect target itself says which.
    @Published private(set) var connectPhase: String?

    /// "Connecting… iQOO 15 · Wi-Fi 192.168.1.42": the phone and the leg being
    /// tried, so a three-leg auto-connect shows where it has got to instead of
    /// the same line for twenty seconds.
    private func progressLine(_ verb: String, _ d: DeviceRef) -> String {
        let route = connectPhase ?? d.routeLabel
        let named = !(d.name ?? "").isEmpty
        switch (named, route) {
        case (true, let r?): return "\(verb) \(d.displayName) · \(r)"
        case (false, let r?): return "\(verb) \(r)"      // the name would only repeat the address
        default: return "\(verb) \(d.displayName)"
        }
    }

    var statusText: String {
        switch state {
        case .disconnected: return L("Disconnected")
        case .connecting(let d): return progressLine(L("Connecting…"), d)
        case .reconnecting(let d): return progressLine(L("Reconnecting…"), d)
        case .waitingForPhone: return L("Waiting for a phone over USB…")
        case .connected(let d): return "\(L("Connected")) · \(d.displayName)"
        // Just the fact: a menu is as wide as its widest row, and a core error
        // runs to a full sentence. The text itself is one click away (copyFailure)
        // and in the banner that announced it.
        case .failed: return L("Connection failed")
        }
    }

    /// Put the last connect failure on the clipboard — the line the menu showed
    /// plus the core's own words when they differ — for pasting into a bug report
    /// or a chat. The menu row that calls this is the only place the full text
    /// is reachable from: the status line abbreviates it.
    func copyFailure() {
        guard let f = lastFailure else { return }
        Pasteboard.copy(f.clipboardText)
        log("copied last failure to the clipboard")
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
        connectRidingPresence(DeviceRef(transport: .lan, ip: ip), reconnect: false)
    }

    // MARK: - Phones on the vivo account

    /// Connect over Wi-Fi to a phone from the account list, at the address it
    /// last reported to the connection centre.
    func connectCloud(_ phone: CloudDevice) {
        guard !phone.ip.isEmpty else { return }
        cancelReconnect()
        connectRidingPresence(DeviceRef(transport: .lan, ip: phone.ip, name: phone.name),
                              reconnect: false)
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
        // Signing in (or switching into account mode) is exactly when a transfer
        // may already be waiting on the relay — don't make the user wait out the
        // poll interval to find out.
        controller.pollCloudTransfersNow()
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
        // The held 10191 connection *is* how the phone sees this Mac, so a session the
        // phone asked for keeps it: presence turns that same connection into the formal
        // connect and hands us its token (no second 10191, which the phone answers by
        // closing the held one — and the device drops to 「未发现」).
        //
        // A connect *we* start is still the old path (`pcsuite_connect_lan` runs its own
        // ConnectFlow on a new connection), so presence steps aside for those.
        let sessionActive: Bool = {
            switch state {
            case .disconnected, .failed: return false
            default: return true
            }
        }()
        let wanted = cloudAccountActive && holdPresence && !(sessionActive && !sessionRidesPresence)
        let ip = cloudPhones.first(where: { !$0.ip.isEmpty })?.ip ?? ""
        guard wanted, !ip.isEmpty else {
            if cloudPresence != nil { stopPresenceHold() }
            return
        }
        if cloudPresence != nil && ip == presencePhoneIP { return }  // already holding this IP
        // The hold re-resolves addresses itself; if it has already moved to what the list
        // now reports, leave it alone instead of restarting the task.
        if let p = cloudPresence, p.phone_ip().toString() == ip {
            presencePhoneIP = ip
            return
        }
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
            // The hold re-resolves the phone's address on its own when it moves (pocketed,
            // off the Wi-Fi, back on a new lease) — follow it, or a connect we start would
            // compare against a stale address and open a second 10191 instead of riding
            // the hold.
            let held = p.phone_ip().toString()
            if !held.isEmpty, held != self.presencePhoneIP {
                log("presence: 目标地址更新 \(self.presencePhoneIP) → \(held)")
                self.presencePhoneIP = held
            }
            // The phone tapped 「连接」 → establish the session with the token presence
            // registered for it (connect only; the mirror window stays user-initiated,
            // matching the phone's semantics).
            let token = p.take_connect_request().toString()
            if !token.isEmpty { self.handlePhoneConnectRequest(token: token) }
        }
    }

    /// React to the phone tapping 「连接」 while we hold presence: open the control
    /// session with the token presence registered on the held connection (no mirror).
    /// No-op if a session is already up.
    ///
    /// The hold stays up throughout — it carries the `bytes:[25]`/`[27]` answers the
    /// phone is waiting for, and it is what the phone shows as this Mac's state. Once
    /// the session resolves we report the outcome so presence can send `[27]`.
    private func handlePhoneConnectRequest(token: String) {
        guard !presencePhoneIP.isEmpty else { return }
        if isConnected {
            // Already connected: still answer, or the phone's button spins forever (the
            // official desktop answers this case too, with an "already connected" reason).
            log("presence: 手机请求连接，但已在连接中 → 直接回执")
            cloudPresence?.report_connect_result(0, "already connected")
            return
        }
        let ip = presencePhoneIP
        log("presence: 手机请求连接 → 建立会话 \(ip)")
        let name = cloudPhones.first(where: { $0.ip == ip })?.name ?? L("Phone")
        sessionRidesPresence = true          // keep the hold: this session rides on it
        phoneAskAwaitingReport = true
        cancelReconnect()   // drop any stale auto-reconnect (e.g. to an old-network IP)
        controller.connect(DeviceRef(transport: .lan, ip: ip, name: name),
                           features: features, reconnect: false, preauthToken: token)
    }

    /// However a phone-initiated session ends, presence has to hear about it: it upgraded
    /// the held 10191 connection for that session, and keeping it afterwards leaves the
    /// phone showing this Mac as connected — with function buttons that do nothing.
    /// Presence then drops it and re-holds a plain discoverable connection.
    private func endPresenceRidingSession() {
        guard sessionRidesPresence else { return }
        sessionRidesPresence = false
        cloudPresence?.report_session_ended()
        log("presence: 会话结束 → 回到「可连」")
    }

    /// Tell the phone how the session it asked for went (presence sends `bytes:[27]`
    /// `{retCode,retMsg}` on the connection it is still holding). The phone gives up
    /// after ~5s, so this runs from the first state change that settles the attempt.
    private func reportPhoneAskResult(_ retCode: Int64, _ message: String) {
        guard phoneAskAwaitingReport else { return }
        phoneAskAwaitingReport = false
        log("presence: 回报手机 retCode=\(retCode) \(message)")
        cloudPresence?.report_connect_result(retCode, message)
    }

    private func stopPresenceHold() {
        presenceStatusTimer?.invalidate()
        presenceStatusTimer = nil
        cloudPresence?.stop()
        cloudPresence = nil
        presencePhoneIP = ""
        if !presenceStatus.isEmpty { presenceStatus = "" }
    }

    /// Start a Wi-Fi connect, riding the presence hold when it is held to that phone:
    /// presence turns that connection into the formal connect and hands back the token,
    /// so the phone keeps showing this Mac throughout. Opening a second 10191 (what a
    /// plain connect does) makes the phone close the held one — the device then reads as
    /// 「未发现」 for as long as our own session lasts.
    ///
    /// Falls back to the plain path whenever there is no hold for that IP, or the upgrade
    /// fails. The upgrade talks to the phone, so it runs off the main thread.
    private func connectRidingPresence(_ ref: DeviceRef, reconnect: Bool) {
        // A Tailscale address is outside the hold's world: presence tracks the
        // phone's Wi-Fi address, and a hold there is what the phone shows as this
        // Mac on its own network. Starting one toward Tailscale would only open a
        // 10191 the plain connect is about to open anyway.
        guard let ip = ref.ip, !ip.isEmpty, ref.remote != true else {
            controller.connect(ref, features: features, reconnect: reconnect)
            return
        }
        // A hold already up for this IP means the phone is there — ride it now.
        if let p = cloudPresence, ip == presencePhoneIP || p.phone_ip().toString() == ip {
            rideHold(p, ref: ref, reconnect: reconnect)
            return
        }
        // No hold yet. Starting one and waiting on `upgrade_for_connect` costs the
        // full 15s when the phone isn't reachable at `ip` — the hold can't connect,
        // so the upgrade never comes — and auto-reconnect pays that per attempt.
        // Ask 10191 first: a reachable phone answers in milliseconds, an absent
        // one costs the 3s probe, not 15s. Start a hold only when it actually
        // answers; otherwise dial 10191 ourselves (a bounded ConnectFlow that
        // fails fast into the caller's own retry).
        guard cloudAccountActive, holdPresence else {
            controller.connect(ref, features: features, reconnect: reconnect)
            return
        }
        probeTCP([ip], port: 10191, timeout: 3) { [weak self] verdicts in
            guard let self else { return }
            if verdicts[ip] == .open {
                log("presence: \(ip) 应答 → 起保活并升级")
                self.startPresenceHold(ip: ip)
                if let p = self.cloudPresence {
                    self.rideHold(p, ref: ref, reconnect: reconnect)
                } else {
                    self.controller.connect(ref, features: self.features, reconnect: reconnect)
                }
            } else {
                log("presence: \(ip) 未应答 → 直接 ConnectFlow, 不等保活升级")
                self.controller.connect(ref, features: self.features, reconnect: reconnect)
            }
        }
    }

    /// Turn an established presence hold into the formal connect: `upgrade_for_connect`
    /// hands back a token registered on the held connection, so the phone keeps
    /// showing this Mac. Falls back to a plain ConnectFlow if the upgrade fails.
    /// The upgrade talks to the phone, so it runs off the main thread.
    private func rideHold(_ p: PcCloudPresence, ref: DeviceRef, reconnect: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let token = p.upgrade_for_connect().toString()
            DispatchQueue.main.async {
                guard let self else { return }
                if token.isEmpty {
                    log("presence: 保活连接升级失败 → 退回独立 ConnectFlow")
                    self.controller.connect(ref, features: self.features, reconnect: reconnect)
                } else {
                    // Connect to the address the hold is actually on: the token was
                    // registered through *that* connection, and the hold may have moved
                    // there on its own (a remembered address goes stale when the phone
                    // changes network).
                    let held = p.phone_ip().toString()
                    let target = held.isEmpty || held == ref.ip
                        ? ref
                        : DeviceRef(transport: .lan, ip: held, name: ref.name)
                    if target.ip != ref.ip {
                        log("presence: 会话改用保活当前地址 \(ref.ip ?? "?") → \(held)")
                    }
                    log("presence: 复用保活连接升级为正式连接(不另开 10191)")
                    self.sessionRidesPresence = true
                    self.controller.connect(target, features: self.features,
                                            reconnect: reconnect, preauthToken: token)
                }
            }
        }
    }

    // MARK: - Automatic transport choice

    /// The remembered device an auto-connect sequence is running for, and the
    /// message to show if its current leg fails. Both cleared once it settles.
    private var autoConnectID: String?
    private var autoConnectFailure: String?
    /// The Tailscale leg an auto-connect still holds in reserve — taken when the
    /// Wi-Fi leg fails instead of reporting that failure — and what to say if it
    /// fails too.
    private var autoConnectTailscale: (ref: DeviceRef, failure: String)?

    /// Connect a remembered phone without making the user pick a transport.
    ///
    /// Cable first — it is faster and needs no address — then Wi-Fi at the
    /// freshest address we have rather than the remembered one, then, when the
    /// user gave the phone a Tailscale address, that: it reaches a phone on any
    /// network, at the price of the round trip, so it is the last resort rather
    /// than a peer of the others. If nothing works the user gets one plain
    /// "can't reach it" instead of the adb diagnostic a wired attempt against an
    /// unplugged phone would produce.
    ///
    /// Caveat, inherited from the wired path generally: USB connects to whatever
    /// phone is on the cable, and the roster is keyed by the phone's own device
    /// id, which nothing tells us until `/base-info` answers. So with two phones
    /// and the *other* one plugged in, this connects to the plugged-in one. That
    /// was already true of the explicit "Connect over USB" item this replaces;
    /// distinguishing them needs an id the cable probe doesn't carry.
    func connectAuto(_ device: KnownDevice) {
        cancelReconnect()
        autoConnectID = device.id
        autoConnectFailure = nil
        autoConnectTailscale = nil
        // Name-only ref: the transport isn't decided yet, and the status line
        // shows `displayName`, which is the phone's name either way — plus the
        // phase, since the ref has no route to show yet.
        connectPhase = L("checking the cable…")
        state = .connecting(DeviceRef(transport: .usb, ip: nil, name: device.name))

        controller.probeUSB { [weak self] link in
            guard let self, self.autoConnectID == device.id else { return }
            if link == .ready {
                // From here it is an ordinary wired connect: let its own errors
                // through, they describe a cable that *is* plugged in.
                log("自动连接: 有线可用 → USB")
                self.autoConnectID = nil
                self.connectPhase = nil
                self.controller.connect(DeviceRef(transport: .usb, ip: nil, name: device.name),
                                        features: self.features, reconnect: false)
                return
            }
            self.beginLanRoute(device, reconnect: false, cableUnauthorized: link == .unauthorized)
        }
    }

    /// Choose and start the LAN route for `device` after a 10191 probe: Wi-Fi
    /// when the phone answers there, Tailscale when it doesn't but a Tailscale
    /// address does, then the slower fall-throughs. The probe is what caps an
    /// unreachable leg at ~3s instead of the ~20s a blind presence-upgrade +
    /// ConnectFlow would take. Shared by the Connect button (`reconnect=false`)
    /// and auto-reconnect (`reconnect=true`) so both fail fast and both fall to
    /// Tailscale when the phone has left the LAN — the everyday "can't connect".
    ///
    /// A probe answer means: `open` — there and listening; `refused` — there but
    /// 10191 is closed (it closes a while after a session ends), which the
    /// ConnectFlow's own presence wake-up can reopen, so worth the ~2s dial but
    /// not the presence hold's wait; `silent` — nothing there, no leg helps.
    private func beginLanRoute(_ device: KnownDevice, reconnect: Bool, cableUnauthorized: Bool) {
        let verb = reconnect ? "自动重连" : "自动连接"
        let wifi = freshestIP(for: device)
        // A Tailscale address that is also the freshest Wi-Fi address is one route.
        let tsIP = device.tailscale.flatMap { $0 == wifi ? nil : $0 }
        let tsRef = tsIP.map { DeviceRef(transport: .lan, ip: $0, name: device.name, remote: true) }
        // The one message shown once every route is spent. A fixable cable points
        // there instead — "check the network" would send the user the wrong way.
        let allFailed = cableUnauthorized
            ? String(format: L("Can't reach %@ — allow USB debugging on the phone, or put it on this network"),
                     device.menuLabel)
            : String(format: tsIP == nil
                        ? L("Can't reach %@ over USB or Wi-Fi — check it's on the same network and awake")
                        : L("Can't reach %@ over USB, Wi-Fi or Tailscale — check it's awake and on a network"),
                     device.menuLabel)

        // Is the attempt this belongs to still the current one?
        let rgen = reconnectGen
        let stillCurrent: () -> Bool = reconnect
            ? { [weak self] in self?.reconnectGen == rgen && self?.autoReconnect == true && self?.reconnectDevice != nil }
            : { [weak self] in self?.autoConnectID == device.id }

        let goTailscale = {
            guard let ref = tsRef else { return }
            self.connectPhase = nil
            if !reconnect { self.autoConnectFailure = allFailed }
            self.controller.connect(ref, features: self.features, reconnect: reconnect)
        }
        // `ridePresence` goes through the hold (phone known present); off dials
        // 10191 directly. `keepTailscale` only applies to the button flow — it
        // stashes the Tailscale leg for `fallBackToTailscale` if Wi-Fi then fails;
        // a reconnect just re-runs this on its next attempt and re-probes.
        let goWiFi = { (ip: String, ridePresence: Bool, keepTailscale: Bool) in
            self.connectPhase = nil
            if !reconnect {
                self.autoConnectFailure = allFailed
                self.autoConnectTailscale = keepTailscale ? tsRef.map { (ref: $0, failure: allFailed) } : nil
            }
            let ref = DeviceRef(transport: .lan, ip: ip, name: device.name)
            if ridePresence {
                self.connectRidingPresence(ref, reconnect: reconnect)
            } else {
                self.controller.connect(ref, features: self.features, reconnect: reconnect)
            }
        }
        // No route answered. The probe is the authoritative reachability test, so
        // there is nothing to gain by dialling a doomed ConnectFlow — but it still
        // counts as one attempt. The button reports it now; a reconnect hands the
        // failure to its budget (`重连次数`, default 1) to retry or give up, so a
        // dead phone stops fast instead of looping.
        let fail = {
            self.connectPhase = nil
            if reconnect {
                self.noteReconnectFailure(allFailed)
            } else {
                self.autoConnectID = nil
                self.state = .failed(allFailed)
                self.scheduleFailedReset()
            }
        }

        guard wifi != nil || tsRef != nil else {
            log("\(verb): 没有任何已知地址 → 失败")
            if reconnect { giveUpReconnect(status: allFailed) } else {
                autoConnectID = nil
                state = .failed(String(format: L("Can't reach %@ — no cable, and no Wi-Fi address is known for it"),
                                       device.menuLabel))
                scheduleFailedReset()
            }
            return
        }
        // A hold already on the Wi-Fi address means the phone is there — no probe.
        if let ip = wifi, presenceHolds(ip) {
            log("\(verb): 保活在 \(ip) 上 → Wi-Fi")
            goWiFi(ip, true, tsRef != nil)
            return
        }
        connectPhase = tsIP == nil ? L("asking Wi-Fi…") : L("asking Wi-Fi and Tailscale…")
        probeTCP([wifi, tsIP].compactMap { $0 }, port: 10191, timeout: 3) { [weak self] verdicts in
            guard let self, stillCurrent() else { return }
            let w = wifi.map { verdicts[$0] ?? .silent } ?? .silent
            let t = tsIP.map { verdicts[$0] ?? .silent } ?? .silent
            let tsUsable = t != .silent
            guard let ip = wifi else { if tsUsable { goTailscale() } else { fail() }; return }
            switch w {
            case .open:
                log("\(verb): Wi-Fi \(ip) 应答 → Wi-Fi")
                goWiFi(ip, true, tsUsable)
            case .refused:
                log("\(verb): Wi-Fi \(ip) 在但 10191 没开 → 直接 ConnectFlow(带唤醒)")
                goWiFi(ip, false, tsUsable)
            case .silent:
                if tsUsable {
                    log("\(verb): Wi-Fi \(ip) 不应答, Tailscale \(tsIP!) → Tailscale")
                    goTailscale()
                } else {
                    log("\(verb): Wi-Fi \(ip) 和 Tailscale \(tsIP ?? "无") 都不应答 → 失败")
                    fail()
                }
            }
        }
    }

    /// Whether the presence hold is up on `ip` right now — the phone is reachable
    /// there by definition, and the connect will ride that connection.
    private func presenceHolds(_ ip: String) -> Bool {
        cloudPresence != nil && presencePhoneIP == ip && presenceStatus == "holding"
    }

    /// Take the Tailscale leg an auto-connect holds in reserve, if any: the Wi-Fi
    /// leg just failed, and there is one more route to try before saying so.
    /// Returns whether it was taken (the caller then stays quiet about the failure).
    private func fallBackToTailscale() -> Bool {
        guard autoConnectID != nil, let ts = autoConnectTailscale else { return false }
        autoConnectTailscale = nil
        autoConnectFailure = ts.failure
        log("自动连接: Wi-Fi 不通 → Tailscale \(ts.ref.ip ?? "?")")
        state = .connecting(ts.ref)
        controller.connect(ts.ref, features: features, reconnect: false)
        return true
    }

    /// Set (or, with a blank address, clear) a remembered phone's Tailscale
    /// address — the route `connectAuto` falls back to when the cable and Wi-Fi
    /// both fail.
    func setTailscaleIP(_ device: KnownDevice, _ ip: String) {
        guard let i = knownDevices.firstIndex(where: { $0.id == device.id }) else { return }
        let ts = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        knownDevices[i].tailscaleIP = ts.isEmpty ? nil : ts
        Store.knownDevices = knownDevices
        log("roster: \(device.menuLabel) Tailscale 地址 → \(ts.isEmpty ? "(清除)" : ts)")
    }

    /// The best Wi-Fi address for a remembered phone.
    ///
    /// In account mode the connection centre knows where the phone is *now*,
    /// which matters because the remembered address goes stale as soon as it
    /// roams to another network. Same preference order as the auto-reconnect.
    private func freshestIP(for device: KnownDevice) -> String? {
        if cloudAccountActive, !device.name.isEmpty,
           let cur = cloudPhones.first(where: { $0.name == device.name && !$0.ip.isEmpty }) {
            if cur.ip != device.lastIP {
                log("自动连接: 用设备列表的当前地址 \(cur.ip)(缓存 \(device.lastIP ?? "无"))")
            }
            return cur.ip
        }
        let cached = device.lastIP ?? ""
        return cached.isEmpty ? nil : cached
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

    /// Abort whatever connect is in flight. Clearing the auto-connect marker is
    /// what stops its cable probe from carrying on into the Wi-Fi leg — the probe
    /// runs on its own thread and `controller.cancel()` cannot reach it.
    func cancelConnect() {
        autoConnectID = nil
        autoConnectFailure = nil
        autoConnectTailscale = nil
        connectPhase = nil
        cancelReconnect()
        controller.cancel()
    }
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
        reconnectLimit = Store.reconnectAttempts
        clipboardEnabled = Store.clipboardEnabled
        clipboardDirection = Store.clipboardDirection
        verifyEnabled = Store.verifyEnabled
        notifyEnabled = Store.notifyEnabled
        notifyOnConnect = Store.notifyOnConnect
        notifyOnFileTransfer = Store.notifyOnFileTransfer
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
        log("auto-reconnect attempt \(reconnectAttempts)/\(maxReconnectAttempts) → \(device.displayName)")
        guard device.transport == .lan else {
            controller.connect(device, features: features, reconnect: true)
            return
        }
        // A Tailscale reconnect stays on Tailscale — the account list only ever
        // carries the phone's Wi-Fi address, which this route exists to do without.
        if device.remote == true {
            connectRidingPresence(device, reconnect: true)
            return
        }
        // Reuse the Connect button's probe-first decision: it tries the freshest
        // Wi-Fi address, falls to the phone's Tailscale address when Wi-Fi is
        // unreachable (a phone that left the LAN — the common "can't connect"),
        // and caps an unreachable attempt at the ~3s probe. Fall back to the plain
        // path only when the phone isn't in the roster (nothing to look tailscale
        // up on).
        if let known = knownDevices.first(where: { $0.matches(device) })
            ?? device.name.flatMap({ n in knownDevices.first { $0.name == n } }) {
            beginLanRoute(known, reconnect: true, cableUnauthorized: false)
        } else {
            connectRidingPresence(device, reconnect: true)
        }
    }

    /// One reconnect attempt failed — whether a real connect error or a probe that
    /// found the phone unreachable. Retry (with backoff) while the budget
    /// (`重连次数`, default 1) allows, else give up. USB is the exception: its
    /// failure may just be a cable not plugged in yet, so it keeps a quiet watch
    /// via `scheduleReconnect`'s own cable probe regardless of the count.
    private func noteReconnectFailure(_ message: String) {
        guard let dev = reconnectDevice else {
            // User-initiated connect failed. The dropdown may be closed, so surface
            // the reason as a notification, and don't leave the status stuck on
            // "failed" forever.
            Notifier.postConnectFailure(message)
            scheduleFailedReset()
            return
        }
        lastReconnectError = message
        // Auto-reconnect switched off under a running attempt: the user ended this
        // themselves, so there's nothing to announce.
        guard autoReconnect else { giveUpReconnect(status: nil, reason: message); return }
        if dev.transport == .usb || reconnectAttempts < maxReconnectAttempts {
            let backoff = min(8.0, pow(2.0, Double(max(1, reconnectAttempts) - 1)))
            log("auto-reconnect retry in \(Int(backoff))s (\(message))")
            scheduleReconnect(gen: reconnectGen, delay: backoff)
        } else {
            giveUpReconnect(status: retriesExhausted(dev), reason: message)
        }
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
            // The status says the budget ran out; the reason is what each attempt
            // actually hit, which is what someone copying the failure wants.
            failureDetail = reason
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
            // The Tailscale address has its own slot; letting it into `lastIP`
            // would make the Wi-Fi leg dial it and the fallback lose its point.
            if ref.transport == .lan, ref.remote != true, let ip = ref.ip, !ip.isEmpty {
                dev.lastIP = ip
            }
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
            // give-up message) should ever see the raw core/adb text — it stays
            // available as the detail behind the menu's copy action.
            if case .failed(let raw) = st {
                self.failureDetail = raw
                st = .failed(self.friendlyConnectError(raw))
            }
            // An auto-connect whose Wi-Fi leg just failed may still have the
            // Tailscale leg to go — that is not a failure the user needs to see.
            if case .failed = st, self.fallBackToTailscale() { return }
            // An auto-connect that got this far already tried the cable. Whatever
            // the last leg says on its own ("no answer from …:10191"), the thing
            // the user needs told is that no route worked.
            if case .failed = st, let note = self.autoConnectFailure {
                st = .failed(note)
            }
            switch st {
            case .connected, .failed, .disconnected:
                self.autoConnectID = nil
                self.autoConnectFailure = nil
                self.autoConnectTailscale = nil
            default: break
            }
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
            // Answer a phone-initiated connect as soon as the attempt settles — the
            // phone is waiting on the held connection for the outcome.
            switch st {
            case .connected:
                self.reportPhoneAskResult(0, "success")
            case .failed(let m):
                self.reportPhoneAskResult(1, m)
                self.endPresenceRidingSession()
            case .disconnected:
                self.reportPhoneAskResult(1, "disconnected")
                self.endPresenceRidingSession()
            default: break
            }
            // Keep the 10191 presence in step with the session: a session the phone
            // asked for rides on the held connection (keep it); one we started runs its
            // own 10191, so presence steps aside for that one.
            self.syncPresenceHold()
            switch st {
            case .connected(let d):
                self.lastDevice = d
                Store.lastDevice = d
                // Highlight the matching roster entry right away; `/base-info` will
                // confirm/correct the id shortly via rememberConnectedDevice.
                self.activeDeviceId = self.knownDevices.first { $0.matches(d) }?.id
                if self.reconnectDevice != nil { log("auto-reconnect succeeded") }
                self.cancelReconnect()
                // Every way in ends here — a click in the menu, the auto-reconnect,
                // the phone's own 「连接」 — and the menu is closed for most of them.
                if self.notifyOnConnect { Notifier.postConnected(d) }
                // Resume mirroring if the window is still open after a recovered drop.
                if self.mirror.isShowing && !self.mirroring {
                    self.controller.startMirror(settings: self.mirrorSettings)
                }
            case .disconnected:
                self.deviceInfo = nil
                self.activeDeviceId = nil
                self.fileTransferNote = nil
            case .failed(let message):
                // A reconnect attempt failed: back off and retry, or give up.
                self.noteReconnectFailure(message)
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
        // The phone stops sending once the relay is switched off; this guard only
        // catches one already in flight at that moment.
        controller.onNotification = { [weak self] app, title, content in
            guard self?.notifyEnabled == true else { return }
            Notifier.postPhoneNotification(app: app, title: title, body: content)
        }
        // The phone's own function buttons on this Mac's card in its connection center.
        // 「投屏」 arrives as openVivoScreen: open the mirror window (which starts the
        // stream), then answer with the same msgId — the phone's button waits on it.
        controller.onConnectCenterRequest = { [weak self] name, msgId in
            guard let self else { return }
            switch name {
            case "openVivoScreen":
                log("手机发起投屏 → 打开投屏窗口")
                self.openMirror()
                self.controller.replyConnectCenter(name, msgId, 0, "")
            case "closeVivoScreen":
                log("手机关闭投屏")
                self.closeMirror()
                self.controller.replyConnectCenter(name, msgId, 0, "")
            default:
                self.controller.replyConnectCenter(name, msgId, -1, "unsupported")
            }
        }
        controller.onPushResult = { [weak self] count, dir, error in
            guard let self else { return }
            if let dir {
                self.noteFileTransfer(String(format: L("Sent → %@"), dir))
                if self.notifyOnFileTransfer { Notifier.postFilesSent(count: count, dir: dir) }
            } else if let error {
                self.noteFileTransfer(String(format: L("Send failed: %@"), error))
                Notifier.postFileSendFailed(error)
            }
        }
        controller.onFileTransfer = { [weak self] type, files, dir, error, source in
            guard let self else { return }
            let fromCloud = source == "cloud"
            switch type {
            case "started":
                // 互传 (EasyShare) 批次在 10191 connect 帧时 started，文件名未知
                // （files 为空）；快传批次 files 至少一个。
                if fromCloud {
                    self.noteFileTransfer(String(format: L("Downloading %lld file(s) from cloud transfer…"),
                                                 files.count), sticky: true)
                } else if files.isEmpty {
                    self.noteFileTransfer(L("Receiving via EasyShare…"), sticky: true)
                } else {
                    self.noteFileTransfer(String(format: L("Receiving %lld file(s)…"), files.count), sticky: true)
                }
            case "done":
                let text = fromCloud
                    ? String(format: L("Cloud transfer: received %lld file(s) → %@"), files.count, dir)
                    : String(format: L("Received %lld file(s) → %@"), files.count, dir)
                self.noteFileTransfer(text)
                if self.notifyOnFileTransfer { Notifier.postFilesReceived(count: files.count, dir: dir) }
            case "failed":
                let text = fromCloud
                    ? String(format: L("Cloud transfer failed: %@"), error)
                    : String(format: L("Receive failed: %@"), error)
                self.noteFileTransfer(text)
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
