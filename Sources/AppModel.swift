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
    /// Live playback stats (0 when not mirroring). `mirrorLatencyMs` is the PC
    /// pipeline cost (frame off the core → enqueued for display), not glass-to-glass.
    @Published private(set) var mirrorFPS: Double = 0
    @Published private(set) var mirrorLatencyMs: Double = 0
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

    // Persisted preferences (default ON).
    @Published var autoReconnect: Bool { didSet { Store.autoReconnect = autoReconnect } }
    // Feature toggles apply to a live session immediately (no reconnect needed);
    // didSet only fires on user changes, never during init.
    @Published var clipboardEnabled: Bool { didSet { Store.clipboardEnabled = clipboardEnabled; applyClipboardLive() } }
    @Published var clipboardDirection: ClipboardDirection { didSet { Store.clipboardDirection = clipboardDirection; applyClipboardLive() } }
    @Published var verifyEnabled: Bool { didSet { Store.verifyEnabled = verifyEnabled; if isConnected { controller.setVerify(enabled: verifyEnabled) } } }
    @Published var notifyEnabled: Bool { didSet { Store.notifyEnabled = notifyEnabled; if isConnected { controller.setNotify(enabled: notifyEnabled) } } }
    /// Show the FPS / latency HUD over the mirror picture.
    @Published var showStats: Bool { didSet { Store.showStats = showStats } }
    @Published var lanIP: String { didSet { Store.lanIP = lanIP } }
    @Published private(set) var resolution: MirrorResolution
    @Published private(set) var bitrate: MirrorBitrate
    @Published private(set) var frameRate: MirrorFrameRate
    /// Request the phone's audio stream (no_audio=false). Demuxed off the video path
    /// but not yet decoded/played — see AudioProbe in the core.
    @Published private(set) var audioEnabled: Bool
    @Published private(set) var lastDevice: DeviceRef?
    /// The remembered-device roster (device-centric; most-recent first).
    @Published private(set) var knownDevices: [KnownDevice]
    /// Id of the currently connected device (nil when disconnected). Set provisionally
    /// on connect, confirmed once `/base-info` returns the real id.
    @Published private(set) var activeDeviceId: String?

    private let controller = SessionController()
    private lazy var mirror = MirrorWindowManager(model: self)

    // Auto-reconnect bookkeeping (main thread). A bumped `reconnectGen` cancels any
    // pending attempt; `reconnectDevice` is non-nil only while a sequence is active.
    private var reconnectGen = 0
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 6
    private var reconnectDevice: DeviceRef?

    /// Set by the mirror window: receives the phone's caret position (mirror
    /// pixel space) or nil when no field is focused. Plain closure (not
    /// @Published) so high-frequency caret updates don't churn SwiftUI.
    var imeCursorSink: ((CGPoint?) -> Void)?
    /// Set by the mirror window: whether the phone has a focused text field, so
    /// the keyboard only types in input mode.
    var imeActiveSink: ((Bool) -> Void)?

    init() {
        autoReconnect = Store.autoReconnect
        clipboardEnabled = Store.clipboardEnabled
        clipboardDirection = Store.clipboardDirection
        verifyEnabled = Store.verifyEnabled
        notifyEnabled = Store.notifyEnabled
        showStats = Store.showStats
        lanIP = Store.lanIP
        resolution = Store.resolution
        bitrate = Store.bitrate
        frameRate = Store.frameRate
        audioEnabled = Store.mirrorAudio
        lastDevice = Store.lastDevice
        knownDevices = Store.knownDevices
        wire()
        if autoReconnect, let dev = lastDevice {
            controller.connect(dev, features: features, reconnect: true)
        }
        if ["1", "2", "3", "4", "5"].contains(ProcessInfo.processInfo.environment["PCSUITE_MIRROR_TEST"]) {
            DispatchQueue.main.async { [weak self] in self?.openMirrorTest() }
        }
    }

    // MARK: - Derived state for the UI

    var isConnected: Bool { if case .connected = state { return true }; return false }
    var isBusy: Bool {
        switch state { case .connecting, .reconnecting: return true; default: return false }
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
        case .connected(let d): return "\(L("Connected")) · \(d.displayName)"
        case .failed(let m): return "\(L("Connection failed")): \(m)"
        }
    }
    var statusIcon: String {
        switch state {
        case .connected: return "checkmark.circle.fill"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .disconnected: return "circle.dashed"
        }
    }
    /// SF Symbol for the menu-bar icon — the only always-visible surface of a
    /// menu-bar agent — so connection state reads at a glance without opening it.
    /// Keeps the phone motif for the two "phone present / absent" states.
    var menuBarSymbol: String {
        switch state {
        case .connected: return "iphone"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .disconnected: return "iphone.slash"
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

    // MARK: - Auto-reconnect on unexpected loss

    /// An established session dropped (USB unplug, Wi-Fi loss, phone ended it). If
    /// auto-reconnect is on, start a bounded backoff sequence to the same device;
    /// otherwise just surface the loss to an open mirror window.
    private func handleConnectionLost(_ device: DeviceRef) {
        guard autoReconnect else {
            mirrorLink = mirror.isShowing ? .lost : .live
            return
        }
        reconnectGen += 1
        reconnectAttempts = 0
        reconnectDevice = device
        mirrorLink = mirror.isShowing ? .reconnecting : .live
        scheduleReconnect(gen: reconnectGen, delay: 0.5)
    }

    /// Fire one reconnect attempt after `delay`, unless the sequence was cancelled
    /// or auto-reconnect was turned off in the meantime.
    private func scheduleReconnect(gen: Int, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.reconnectGen == gen, self.autoReconnect,
                  let dev = self.reconnectDevice else { return }
            self.reconnectAttempts += 1
            log("auto-reconnect attempt \(self.reconnectAttempts)/\(self.maxReconnectAttempts) → \(dev.displayName)")
            self.controller.connect(dev, features: self.features, reconnect: true)
        }
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
        reconnectDevice = nil
        mirrorLink = .live
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

    /// Toggle phone-audio request; restarts the live stream if mirroring.
    func setAudio(_ on: Bool) {
        guard on != audioEnabled else { return }
        audioEnabled = on
        Store.mirrorAudio = on
        if mirroring { controller.restartMirror(settings: mirrorSettings) }
    }

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
            self.state = st
            // The QR pairing window only exists while waiting for a scan; dismiss it
            // once we leave that wait (connected / failed / disconnected).
            switch st {
            case .connecting, .reconnecting: break
            default: QRPairingWindowController.shared.close()
            }
            switch st {
            case .connected(let d):
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
            case .failed(let message):
                // A reconnect attempt failed: back off and retry, or give up.
                guard self.reconnectDevice != nil else {
                    // User-initiated connect failed. The dropdown may be closed, so
                    // surface the reason as a notification, and don't leave the menu
                    // status stuck on "failed" forever.
                    Notifier.postConnectFailure(message)
                    self.scheduleFailedReset()
                    break
                }
                if self.autoReconnect, self.reconnectAttempts < self.maxReconnectAttempts {
                    let backoff = min(8.0, pow(2.0, Double(self.reconnectAttempts - 1)))
                    log("auto-reconnect retry in \(Int(backoff))s")
                    self.scheduleReconnect(gen: self.reconnectGen, delay: backoff)
                } else {
                    log("auto-reconnect gave up after \(self.reconnectAttempts) attempts")
                    let showing = self.mirror.isShowing
                    self.cancelReconnect()
                    self.mirrorLink = showing ? .lost : .live
                }
            default:
                break
            }
        }
        controller.onConnectionLost = { [weak self] device in
            self?.handleConnectionLost(device)
        }
        controller.onMirroring = { [weak self] on, layer in
            guard let self else { return }
            self.mirroring = on
            self.displayLayer = layer
            if !on {
                self.videoSize = .zero; self.privacyState = ""; self.screenLocked = false
                self.mirrorFPS = 0; self.mirrorLatencyMs = 0
            }
        }
        controller.onStats = { [weak self] fps, lat in
            self?.mirrorFPS = fps
            self?.mirrorLatencyMs = lat
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
        controller.onDeviceInfo = { [weak self] info in
            guard let self else { return }
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
