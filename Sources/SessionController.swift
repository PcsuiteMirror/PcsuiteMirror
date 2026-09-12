import Foundation
import AVFoundation

/// Connection lifecycle state, surfaced to the UI.
enum ConnState: Equatable {
    case disconnected
    case connecting(DeviceRef)
    case reconnecting(DeviceRef)
    /// Auto-reconnect is armed for a USB device, but there is no phone on the
    /// cable yet. Produced by `AppModel`, not the controller: nothing is in
    /// flight, we're only watching — so it must not read as "connecting".
    case waitingForPhone(DeviceRef)
    case connected(DeviceRef)
    case failed(String)
}

/// What the USB cable looks like right now, without connecting to it
/// (see `SessionController.probeUSB`).
enum USBLink: String {
    /// A phone is attached and authorized — a connect can proceed.
    case ready
    /// Nothing usable on the cable: the normal resting state after an unplug.
    case noDevice = "no-device"
    /// Attached, but USB debugging hasn't been allowed on the phone yet.
    case unauthorized
    /// adb itself is missing or broken — USB can't work until that's fixed.
    case noAdb = "no-adb"
}

/// Which background features to arm on connect.
struct ConnectFeatures {
    var clipboard: Bool
    var clipRecv: Bool
    var clipSend: Bool
    var verify: Bool
    var notify: Bool
}

/// Owns the Rust FFI handles and runs everything off the main thread.
///
/// Design notes (the hard part of making this production-grade):
/// - All connect/disconnect/mirror lifecycle runs on one **serial** queue, so the
///   handles are never mutated concurrently.
/// - The blocking pollers (`next_frame`, `next_verify_code`) run on dedicated
///   threads that hold a strong reference to the Rust handle while parked. We can't
///   drop the handle out from under them, so teardown asks the handle to stop
///   (`PcScreen.stop()` / `PcSession.stop_verify()`), then **waits** for the polling
///   thread to exit (semaphore) before releasing the handle. That guarantees the
///   Rust `Session`/`ScreenStream` actually drop — aborting their tasks and freeing
///   the control WS / adb forwards — which is required because the phone only allows
///   one control session at a time.
/// - Callbacks are always delivered on the main queue.
final class SessionController {
    // Delivered on the main queue.
    var onState: ((ConnState) -> Void)?
    var onMirroring: ((Bool, AVSampleBufferDisplayLayer?) -> Void)?
    var onFormat: ((Int, Int) -> Void)?
    /// Throttled playback stats `(fps, pipelineLatencyMs)`, delivered on the main
    /// queue while mirroring.
    var onStats: ((Double, Double) -> Void)?
    var onVerifyCode: ((String) -> Void)?
    /// A phone notification was forwarded: `(appName, title, content)`. Delivered on
    /// the main queue while connected (if the notify feature is armed).
    var onNotification: ((String, String, String) -> Void)?
    /// A phone→PC「快传」batch event: `(type, files, dir, error)` where type is
    /// "started" / "done" / "failed" / "cancelled". Delivered on the main queue
    /// while connected.
    var onFileTransfer: ((String, [String], String, String) -> Void)?
    /// Result of a `pushFiles` call: `(phoneDir, nil)` on success, `(nil, error)`
    /// on failure. Delivered on the main queue.
    var onPushResult: ((String?, String?) -> Void)?
    /// Phone device info (storage capacity, model, OS) fetched after connect.
    /// Delivered on the main queue.
    var onDeviceInfo: ((PhoneInfo) -> Void)?
    /// Privacy / secure-screen state token ("clear" / "password" / "safety" /
    /// "lockScreen"). Delivered on the main queue while mirroring.
    var onPrivacy: ((String) -> Void)?
    /// Device keyguard lock state, delivered on the main queue while mirroring. `true`
    /// when the phone reports `DEVICE_INFO:is_lock` (no frames will arrive until the
    /// user unlocks); cleared when real frames resume. Tracked separately from
    /// `onPrivacy` because the phone reports foreground-window privacy as "clear" even
    /// while the keyguard is locked.
    var onLock: ((Bool) -> Void)?
    /// Phone IME state, delivered on the main queue while mirroring:
    /// `(active, hasCaret, caretX, caretY)`. `active` = a text field is focused
    /// (so the keyboard should type); `caret*` is the on-device caret in mirror
    /// pixel space when `hasCaret` is true.
    var onInputState: ((Bool, Bool, Double, Double) -> Void)?
    /// An *established* session ended on its own (the shared control WS closed or
    /// errored — covers USB unplug, Wi-Fi loss, and the phone ending the session,
    /// whether idle or mid-mirror). Delivered on the main queue *after* the dead
    /// session has been torn down, carrying the device that was connected and
    /// `phoneEnded`: true when the phone closed the session on purpose (the user
    /// disconnected there — not worth dialling back), false when the link dropped.
    /// Not fired for user-initiated `disconnect()`.
    var onConnectionLost: ((_ device: DeviceRef, _ phoneEnded: Bool) -> Void)?

    private let queue = DispatchQueue(label: "com.pcsuite.session")
    private let inputQueue = DispatchQueue(label: "com.pcsuite.input")

    // Handles + worker bookkeeping. Touched on `queue` (and the worker threads they
    // belong to). `sessionRef`/`mirroring` are read from `inputQueue`/main under lock.
    private var session: PcSession?
    private var screen: PcScreen?
    private var feeder: HEVCFeeder?
    // In-flight QR pairing handle (lock-guarded): retained so cancel() can abort the
    // blocking wait_phone() and release the :9199 listener.
    private var pairing: PcPairing?

    private var verifyDone: DispatchSemaphore?
    private var notifyDone: DispatchSemaphore?
    private var fileTransDone: DispatchSemaphore?
    private var frameDone: DispatchSemaphore?
    private var privacyDone: DispatchSemaphore?
    private var cursorDone: DispatchSemaphore?
    private var audioDone: DispatchSemaphore?
    private var watchDone: DispatchSemaphore?

    // Phone-audio playback, live while mirroring. `audioMuted` is remembered here so
    // a mute set before/between streams still applies to the next player.
    private var audioPlayer: MirrorAudioPlayer?
    private var audioMuted = false

    // Disconnect bookkeeping (touched on `queue`). `connGen` rises on every connect
    // and every detected loss, so a watcher/recovery callback queued for a stale
    // connection is ignored. `currentDevice` is what the live session connected to,
    // reported back when it drops.
    private var connGen = 0
    private var currentDevice: DeviceRef?

    // True while the phone reports a secure/privacy screen (touched on `queue`).
    // The phone stops the video then, so we suppress black-screen recovery.
    private var privacyActive = false
    // True while the phone's keyguard is locked (`DEVICE_INFO:is_lock`; touched on
    // `queue`). No frames arrive until the user unlocks, and the phone keeps the
    // stream alive meanwhile — so, like `privacyActive`, this suppresses black-screen
    // recovery (a restart can't un-lock the phone). Cleared when real frames resume.
    private var lockActive = false

    // Black-screen recovery (touched on `queue`). If a freshly started stream delivers
    // no frame within a few seconds — the phone's screen service didn't fully reset
    // between a stop and the next start — tear it down and start again. Bounded, so a
    // genuinely stuck phone (e.g. locked screen) doesn't restart-loop forever.
    private var mirrorGen = 0
    private var firstFrameSeen = false
    private var mirrorRecoveries = 0
    private let mirrorRecoverDelay: TimeInterval = 4.0
    private let mirrorRecoverMax = 2

    private let lock = NSLock()
    private var sessionRef: PcSession?   // lock-guarded snapshot for input dispatch
    // Connect-attempt generation (lock-guarded). Bumped when an attempt starts and
    // when one is cancelled, so a connect whose result arrives late — cancelled, or
    // superseded by a newer attempt — knows it is stale and stays silent instead of
    // reporting state for a connection nobody is waiting for any more.
    private var attemptGen = 0

    // Coalesced pointer-move state (lock-guarded).
    private var pendingMove: (UInt8, Int, Int, Int, Int)?
    private var moveDraining = false

    // MARK: - Connect / disconnect

    /// `preauthToken` — a token the phone has already accepted, handed over by the
    /// presence hold after the phone itself tapped 「连接」. With it we open 10380
    /// directly instead of running our own ConnectFlow: a second 10191 connection makes
    /// the phone close the one presence is holding, and that connection is what keeps
    /// this Mac visible in the phone's connection center.
    func connect(_ device: DeviceRef, features: ConnectFeatures, reconnect: Bool,
                 preauthToken: String? = nil) {
        let gen = beginAttempt()
        queue.async { [self] in
            guard !isStale(gen) else { return }    // cancelled before we even started
            teardownLocked()                       // ensure any prior session is gone
            emitState(reconnect ? .reconnecting(device) : .connecting(device))
            do {
                let s: PcSession
                applyIdentityToCore()          // openID (for the sign + clipboard) + seeds
                switch device.transport {
                case .usb: s = try pcsuite_connect_usb()
                case .lan where (preauthToken?.isEmpty == false):
                    let ip = device.ip ?? ""
                    log("LAN connect \(ip) (复用 presence 已注册的 token, 不另开 10191)")
                    s = try pcsuite_connect_lan_token(ip, preauthToken!)
                case .lan:
                    let ip = device.ip ?? ""
                    // Ask for the nearby WLAN connect (connectType=2) and let the core
                    // resolve the seed — a configured one, else the phone's own seed
                    // from the account's device list — falling back to the seedless
                    // connectType=1 only when there is none. The two are not
                    // interchangeable to the phone: connectType=1 is the FARAWAYWLAN
                    // (remote) path, so defaulting to it on our own LAN is wrong. An
                    // explicit "connect without a seed" preference still forces it.
                    let remote = Store.lanUseRemote
                    log("LAN connect \(ip) (connectType=\(remote ? "1" : "2, 无 seed 时回落 1"))")
                    s = try pcsuite_connect_lan(ip, remote)
                }
                if isStale(gen) {                  // cancelled mid-connect → discard
                    // Dropping `s` releases the Rust session, which closes the
                    // control WS the phone would otherwise keep reserved.
                    log("connect cancelled; discarding session")
                    return
                }
                finishConnect(s, device: device, features: features)
            } catch {
                // A stale attempt stays silent: `cancel()` already put the UI back to
                // .disconnected, and a late .failed would clobber whatever the user
                // has started since.
                if !isStale(gen) { emitState(.failed(ffiMessage(error))) }
                log("connect failed: \(ffiMessage(error))")
            }
        }
    }

    /// Is a phone on the USB cable? Answers without connecting — and without the
    /// adb diagnostics a failed connect would produce — so a caller waiting for a
    /// cable can ask repeatedly and stay quiet about it.
    ///
    /// Runs off both the main thread *and* the serial `queue`: a connect parks
    /// `queue` for its whole duration, and the point of this call is to answer
    /// while nothing else is going on. Result delivered on the main queue.
    func probeUSB(_ done: @escaping (USBLink) -> Void) {
        Thread.detachNewThread {
            let link = USBLink(rawValue: pcsuite_usb_probe().toString()) ?? .noDevice
            DispatchQueue.main.async { done(link) }
        }
    }

    /// Arm the requested features on a freshly-connected session, register it, start
    /// the disconnect watcher, and report `.connected`. Runs on `queue`; the caller
    /// has already passed the post-connect cancel check. Shared by every transport
    /// (USB / LAN / QR pairing).
    private func finishConnect(_ s: PcSession, device: DeviceRef, features: ConnectFeatures) {
        if features.clipboard {
            do { try s.enable_clipboard(features.clipRecv, features.clipSend) }
            catch { log("clipboard enable failed: \(ffiMessage(error))") }
        }
        if features.verify {
            s.enable_verify()
            startVerifyLoop(s)
        }
        if features.notify {
            s.enable_notify()
            startNotifyLoop(s)
        }
        // Phone→PC「快传」receiver — always armed (no toggle; it only listens).
        do {
            try s.enable_file_transfer(Self.fileSaveDir)
            startFileTransferLoop(s)
        } catch { log("file-transfer enable failed: \(ffiMessage(error))") }
        setSession(s)
        connGen += 1
        currentDevice = device
        startDisconnectWatcher(s, gen: connGen)
        emitState(.connected(device))
        emitMirroring(false, nil)
        fetchDeviceInfo(s)          // storage/model panel data (off-queue)
        log("connected ✓ (\(device.displayName))")
    }

    /// QR pairing (local `ls=true` variant): begin pairing, hand the QR payload to
    /// `onQR` (main queue) to display, then wait on a **dedicated thread** (the wait
    /// can block up to the timeout, so it must not occupy the serial `queue`) for the
    /// phone to scan and report its IP to `:9199`. On a hit, resume on `queue` and
    /// connect — emitting the same `.connected` state as any other transport.
    func pairAndConnect(features: ConnectFeatures, onQR: @escaping (String) -> Void) {
        let gen = beginAttempt()
        queue.async { [self] in
            guard !isStale(gen) else { return }
            teardownLocked()                    // ensure any prior session is gone
            applyIdentityToCore()               // nicer d=/u= in the QR (not required)
            let pairing = pcsuite_pair_begin("")  // "" → auto-detect this Mac's LAN IP
            lock.lock(); self.pairing = pairing; lock.unlock()
            let url = pairing.qr_url().toString()
            emit { onQR(url) }
            emitState(.connecting(DeviceRef(transport: .lan, ip: nil, name: L("Scan to pair"))))

            let t = Thread { [weak self] in
                let result = Result { try pairing.wait_phone(180_000) }
                guard let self else { return }
                self.queue.async {
                    self.lock.lock(); self.pairing = nil; self.lock.unlock()
                    switch result {
                    case .success(let paired):
                        if self.isStale(gen) { return }
                        let ip = paired.phone_ip().toString()
                        let name = paired.device_name().toString()
                        let dev = DeviceRef(transport: .lan,
                                            ip: ip.isEmpty ? nil : ip,
                                            name: name.isEmpty ? nil : name)
                        do {
                            let s = try paired.connect()
                            if self.isStale(gen) { return }
                            self.finishConnect(s, device: dev, features: features)
                            log("QR paired ✓ (\(name) \(ip))")
                        } catch {
                            if !self.isStale(gen) { self.emitState(.failed(ffiMessage(error))) }
                            log("QR connect failed: \(ffiMessage(error))")
                        }
                    case .failure(let error):
                        if !self.isStale(gen) { self.emitState(.failed(ffiMessage(error))) }
                        log("QR pairing ended: \(ffiMessage(error))")
                    }
                }
            }
            t.name = "qr-pair-wait"
            t.start()
        }
    }

    /// Abandon an in-flight connect attempt.
    ///
    /// Everything here is deliberately *off* the serial `queue`: a connect is one
    /// long blocking FFI call that occupies the queue for its whole duration, so a
    /// cancel that queued behind it would only run once the thing it is meant to
    /// cancel had already finished — which is exactly why cancelling a Wi-Fi connect
    /// to a phone whose IP has changed appeared to do nothing at all.
    /// So: bump the attempt generation (the result, whenever it lands, is now
    /// stale), tell the core to drop the in-flight sockets, and put the UI back to
    /// `.disconnected` right away.
    func cancel() {
        lock.lock(); attemptGen += 1; let p = pairing; lock.unlock()
        p?.cancel()              // abort an in-flight QR wait, freeing the :9199 listener
        pcsuite_cancel_connect() // abort the blocking connect_usb/connect_lan itself
        // Only when nothing is established: `disconnect()` also routes through here,
        // and it emits .disconnected itself once the live session is actually gone.
        if snapshotSession() == nil {
            emitState(.disconnected)
            log("connect cancelled")
        }
    }

    func disconnect() {
        cancel()
        queue.async { [self] in
            teardownLocked()
            emitState(.disconnected)
            log("disconnected")
        }
    }

    /// Stop mirroring and verify, then release the session. Runs on `queue`.
    private func teardownLocked() {
        // Tell the phone the clipboard is going offline *before* dropping the session.
        // Without this graceful frame the phone keeps a stale clipboard registration
        // across the socket close, and phone→PC sync silently dies on the next connect.
        // No-op (fast) if the link is already dead, so it's safe on connection-loss too.
        if let s = session { s.stop_clipboard() }
        stopMirrorLocked()
        if let s = session, let done = verifyDone {
            s.stop_verify()
            done.wait()                 // block until the verify thread exits
            verifyDone = nil
        }
        if let s = session, let done = notifyDone {
            s.stop_notify()
            done.wait()                 // block until the notify thread exits
            notifyDone = nil
        }
        if let s = session, let done = fileTransDone {
            s.stop_file_transfer()
            done.wait()                 // block until the file-transfer thread exits
            fileTransDone = nil
        }
        if let s = session, let done = watchDone {
            s.stop_watch()
            done.wait()                 // block until the disconnect watcher exits
            watchDone = nil
        }
        setSession(nil)                 // last ref → Rust Session drops → cleanup
    }

    // MARK: - Live feature toggles (apply to a running session without a reconnect)

    /// Enable/disable (or re-aim) clipboard sync on the live session. Re-arming with
    /// new recv/send also covers a direction change. Safe no-op when disconnected.
    func setClipboard(enabled: Bool, recv: Bool, send: Bool) {
        queue.async { [self] in
            guard let s = session else { return }
            if enabled {
                do { try s.enable_clipboard(recv, send) }
                catch { log("clipboard enable failed: \(ffiMessage(error))") }
            } else {
                s.stop_clipboard()
            }
        }
    }

    /// Start/stop the verify-code relay on the live session (and its poll thread).
    func setVerify(enabled: Bool) {
        queue.async { [self] in
            guard let s = session else { return }
            if enabled {
                guard verifyDone == nil else { return }   // already running
                s.enable_verify()
                startVerifyLoop(s)
            } else if let done = verifyDone {
                s.stop_verify()
                done.wait()
                verifyDone = nil
            }
        }
    }

    /// Start/stop the notification relay on the live session (and its poll thread).
    func setNotify(enabled: Bool) {
        queue.async { [self] in
            guard let s = session else { return }
            if enabled {
                guard notifyDone == nil else { return }   // already running
                s.enable_notify()
                startNotifyLoop(s)
            } else if let done = notifyDone {
                s.stop_notify()
                done.wait()
                notifyDone = nil
            }
        }
    }

    // MARK: - Mirroring

    func startMirror(settings: MirrorSettings) {
        queue.async { [self] in startMirrorLocked(settings: settings) }
    }

    /// Apply new encoder settings to a live mirror: stop the current stream and
    /// reopen it (SCREEN_START params are fixed per stream).
    func restartMirror(settings: MirrorSettings) {
        queue.async { [self] in
            guard screen != nil else { return }
            stopMirrorLocked()
            startMirrorLocked(settings: settings)
        }
    }

    private func startMirrorLocked(settings: MirrorSettings) {
        guard let s = session, screen == nil else { return }
        do {
            let sc = try s.start_screen(settings.maxSize, settings.bitRate, settings.frameRate, settings.audio)
            let f = HEVCFeeder()
                f.onFormat = { [weak self] w, h in self?.emit { self?.onFormat?(w, h) } }
                f.onStats = { [weak self] fps, lat in self?.onStats?(fps, lat) }   // already on main
                screen = sc
                feeder = f
                mirrorGen += 1
                let gen = mirrorGen
                firstFrameSeen = false
                let done = DispatchSemaphore(value: 0)
                frameDone = done
                let pump = Thread { [weak self] in
                    var first = true
                    while true {
                        let v = sc.next_frame()
                        let n = Int(v.len())
                        if n == 0 { break }          // stopped or stream ended
                        if first {                   // first real frame → stream is alive
                            first = false
                            self?.queue.async {
                                self?.firstFrameSeen = true
                                self?.mirrorRecoveries = 0   // healthy → restore retry budget
                                // A real frame means the keyguard is gone (no frames flow
                                // while locked) — clear the lock prompt. This is the
                                // authoritative unlock signal; the phone's NOTIFY_PASS
                                // never reliably reports the keyguard clearing.
                                if self?.lockActive == true {
                                    self?.lockActive = false
                                    self?.emit { self?.onLock?(false) }
                                }
                            }
                        }
                        f.handle(Data(bytes: v.as_ptr(), count: n))
                    }
                    done.signal()
                    // The stream ended. If we never asked it to stop (the generation
                    // is unchanged) and the session-level disconnect watcher hasn't
                    // already torn things down, the mirror link dropped on its own —
                    // recover it. The short grace lets a full-connection loss be
                    // claimed by the disconnect watcher first (it does a complete
                    // reconnect), so we don't fire a doomed restart against a dead link.
                    self?.queue.asyncAfter(deadline: .now() + 0.8) {
                        guard let self, self.mirrorGen == gen, self.screen != nil else { return }
                        self.handleStreamDropped(settings: settings)
                    }
                }
                pump.name = "frame-pump"
                pump.stackSize = 4 << 20
                pump.start()

                // Privacy / secure-screen poller. The phone stops the video when
                // it shows a secure surface (fingerprint, password, lock screen)
                // and pushes a state token; the UI shows a "handle on phone" hint.
                privacyActive = false
                lockActive = false
                let pdone = DispatchSemaphore(value: 0)
                privacyDone = pdone
                let privacyPump = Thread { [weak self] in
                    while true {
                        let tok = sc.next_privacy_event().toString()
                        if tok.isEmpty { break }     // stopped or stream ended
                        if tok == "screenLocked" {
                            // Keyguard lock (DEVICE_INFO:is_lock) — its own state, NOT a
                            // privacy token. Cleared by the first real frame (the unlock
                            // signal), not by the phone's NOTIFY_PASS:clear.
                            self?.queue.async { self?.lockActive = true }
                            self?.emit { self?.onLock?(true) }
                        } else {
                            let active = (tok != "clear")
                            self?.queue.async { self?.privacyActive = active }
                            self?.emit { self?.onPrivacy?(tok) }
                        }
                    }
                    pdone.signal()
                }
                privacyPump.name = "privacy-pump"
                privacyPump.start()

                // IME caret poller: the phone reports the focused field's caret
                // position so the PC can place its candidate window there.
                let cdone = DispatchSemaphore(value: 0)
                cursorDone = cdone
                let cursorPump = Thread { [weak self] in
                    while true {
                        let s = sc.next_input_cursor().toString()
                        if s.isEmpty { break }       // stopped or stream ended
                        switch s {
                        case "on":  self?.emit { self?.onInputState?(true, false, 0, 0) }
                        case "off": self?.emit { self?.onInputState?(false, false, 0, 0) }
                        default:
                            let p = s.split(separator: ",")
                            if p.count == 2, let x = Double(p[0]), let y = Double(p[1]) {
                                self?.emit { self?.onInputState?(true, true, x, y) }
                            }
                        }
                    }
                    cdone.signal()
                }
                cursorPump.name = "ime-cursor-pump"
                cursorPump.start()

                // Phone audio: the core demuxes AAC packets off the same mirror WS.
                // The phone mutes its own speaker while it streams them, so this pump
                // is the only thing that makes the sound audible anywhere.
                //
                // Armed unconditionally, even when the stream opened with the audio
                // routed to the phone: routing is switchable live (setAudioToPC), and
                // a pump that only exists at start would leave a mid-session switch
                // silent. It costs one parked thread; with no audio arriving the
                // player never even builds its graph.
                let player = MirrorAudioPlayer()
                player.muted = audioMuted
                audioPlayer = player
                let adone = DispatchSemaphore(value: 0)
                audioDone = adone
                let audioPump = Thread {
                    while true {
                        let v = sc.next_audio_frame()
                        let n = Int(v.len())
                        if n == 0 { break }     // stopped or stream ended
                        player.feed(Data(bytes: v.as_ptr(), count: n))
                    }
                    adone.signal()
                }
                audioPump.name = "audio-pump"
                audioPump.start()

                if settings.audio { rearmPhoneAudio(gen: gen) }

                emitMirroring(true, f.layer)
                scheduleMirrorWatchdog(gen: gen, settings: settings)
                // Banner labels the per-second `mirror_stats` / `mirror-pipe` lines that
                // follow, so a captured log self-identifies its transport + encoder params.
                log("mirroring ✓ transport=\(currentDevice?.transport.rawValue ?? "?") maxSize=\(settings.maxSize) bitrate=\(settings.bitRate) fps=\(settings.frameRate) audio=\(settings.audio)")
            } catch {
                emitMirroring(false, nil)
                log("start mirror failed: \(ffiMessage(error))")
            }
    }

    /// If this stream generation hasn't produced a single frame after a short grace
    /// period (black screen), restart it once the phone has had a moment to reset —
    /// up to `mirrorRecoverMax` times. Only fires while still mirroring this exact
    /// generation, so it never disturbs a working stream or a closed window.
    private func scheduleMirrorWatchdog(gen: Int, settings: MirrorSettings) {
        queue.asyncAfter(deadline: .now() + mirrorRecoverDelay) { [weak self] in
            guard let self,
                  self.mirrorGen == gen, self.screen != nil, !self.firstFrameSeen,
                  !self.privacyActive,  // black screen is expected during a secure screen
                  !self.lockActive      // …or while the keyguard is locked (no restart can fix that)
            else { return }
            guard self.mirrorRecoveries < self.mirrorRecoverMax else {
                log("mirror still black after \(self.mirrorRecoveries) recoveries; leaving as-is")
                return
            }
            self.mirrorRecoveries += 1
            log("no frames in \(self.mirrorRecoverDelay)s → recovering mirror (attempt \(self.mirrorRecoveries))")
            self.stopMirrorLocked()
            self.startMirrorLocked(settings: settings)
        }
    }

    func stopMirror() {
        queue.async { [self] in stopMirrorLocked() }
    }

    /// Make the phone actually start streaming audio for a freshly opened mirror.
    ///
    /// `SCREEN_START.no_audio:false` isn't reliable on its own: the phone only arms
    /// capture there when its encoder wasn't already running (`ScreenController`:
    /// `if (!isEncoderRunning) { … startRecord() }`), so a stream opened while a
    /// previous one is still winding down comes up silent. The live routing message
    /// has no such guard — but `startRecord()` *also* early-returns when the phone
    /// believes it is already recording, a belief that survives a stream that ended
    /// without a clean stop. So: stop first, then start. Both are no-ops when the
    /// phone's state is already what we ask for.
    private func rearmPhoneAudio(gen: Int) {
        let stillLive: () -> PcSession? = { [weak self] in
            guard let self, self.mirrorGen == gen, self.screen != nil else { return nil }
            return self.session
        }
        queue.asyncAfter(deadline: .now() + 0.6) {
            guard let s = stillLive() else { return }
            _ = s.set_audio_to_pc(false)          // clear any stale capture state
        }
        queue.asyncAfter(deadline: .now() + 0.9) {
            guard let s = stillLive() else { return }
            let sent = s.set_audio_to_pc(true)
            log("audio: asked the phone to start capture (delivered=\(sent))")
        }
    }

    // MARK: - Audio controls (live, no stream restart)

    /// Move the phone's audio between this Mac and the phone's own speaker while
    /// mirroring. `SCREEN_START` carries the same choice for the *next* stream, so
    /// a no-op here (not mirroring, or view-only) still takes effect on reconnect.
    func setAudioToPC(_ toPC: Bool) {
        queue.async { [self] in
            guard let s = session, screen != nil else { return }
            let ok = s.set_audio_to_pc(toPC)
            log("audio → \(toPC ? "Mac" : "phone")\(ok ? "" : " (no control channel; applies next stream)")")
        }
    }

    /// Silence this Mac's output without changing where the phone sends its audio.
    func setAudioMuted(_ muted: Bool) {
        queue.async { [self] in
            audioMuted = muted
            audioPlayer?.muted = muted
            log("audio \(muted ? "muted" : "unmuted") on this Mac")
        }
    }

    private func stopMirrorLocked() {
        guard let sc = screen, let done = frameDone else { return }
        mirrorGen += 1                  // invalidate this stream's drop-recovery dispatch
        sc.stop()                       // unblocks the frame, privacy, IME and audio pumps
        done.wait()                     // block until the frame pump exits
        privacyDone?.wait()             // and the privacy pump
        cursorDone?.wait()              // and the IME-caret pump
        audioDone?.wait()               // and the audio pump, if it was armed
        audioPlayer?.stop()             // …then tear the playback graph down
        audioPlayer = nil
        frameDone = nil
        privacyDone = nil
        cursorDone = nil
        audioDone = nil
        privacyActive = false
        lockActive = false
        screen = nil
        feeder = nil
        emitMirroring(false, nil)
        log("mirroring stopped")
    }

    // MARK: - Verify loop

    private func startVerifyLoop(_ s: PcSession) {
        let done = DispatchSemaphore(value: 0)
        verifyDone = done
        let t = Thread { [weak self] in
            while true {
                let raw = s.next_verify_code().toString()
                if raw.isEmpty { break }            // stopped or session ended
                let code = raw.components(separatedBy: "\t").first ?? raw
                self?.emit { self?.onVerifyCode?(code) }
            }
            done.signal()
        }
        t.name = "verify-loop"
        t.start()
    }

    // MARK: - Notification relay loop

    private func startNotifyLoop(_ s: PcSession) {
        let done = DispatchSemaphore(value: 0)
        notifyDone = done
        let t = Thread { [weak self] in
            while true {
                let raw = s.next_notification().toString()
                if raw.isEmpty { break }            // stopped or session ended
                let f = raw.components(separatedBy: "\t")
                let app = f.count > 0 ? f[0] : ""
                let title = f.count > 1 ? f[1] : ""
                let content = f.count > 2 ? f[2] : ""
                self?.emit { self?.onNotification?(app, title, content) }
            }
            done.signal()
        }
        t.name = "notify-loop"
        t.start()
    }

    // MARK: - File transfer (push + phone→PC「快传」receive)

    /// Where phone→PC「快传」files land (the core creates it on demand).
    static let fileSaveDir = NSHomeDirectory() + "/Downloads/PcsuiteMirror"

    /// Upload local files to the phone (the drag-and-drop path). Runs on a
    /// detached thread holding a strong session ref — an upload can take minutes
    /// and must not park the serial `queue` (same pattern as fetchDeviceInfo).
    /// Regular files only; directories are dropped here because the core rejects
    /// them (v1). Result reported via `onPushResult` on the main queue.
    func pushFiles(_ urls: [URL]) {
        guard let s = snapshotSession() else {
            log("pushFiles: not connected")
            emit { self.onPushResult?(nil, "not connected") }
            return
        }
        let files = urls.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
        guard !files.isEmpty else {
            log("pushFiles: no regular files in the drop (folders unsupported)")
            emit { self.onPushResult?(nil, L("Folders aren't supported yet — drop regular files")) }
            return
        }
        Thread.detachNewThread { [weak self] in
            let vec = RustVec<RustString>()
            for f in files { vec.push(value: RustString(f.path)) }
            do {
                // "" = the phone's default save directory.
                let dir = try s.push_files(vec, RustString("")).toString()
                self?.emit { self?.onPushResult?(dir, nil) }
            } catch {
                let msg = ffiMessage(error)
                log("push failed: \(msg)")
                self?.emit { self?.onPushResult?(nil, msg) }
            }
        }
    }

    private func startFileTransferLoop(_ s: PcSession) {
        let done = DispatchSemaphore(value: 0)
        fileTransDone = done
        let t = Thread { [weak self] in
            while true {
                let raw = s.next_file_transfer_event().toString()
                if raw.isEmpty { break }            // stopped or session ended
                var type = "", files: [String] = [], dir = "", error = ""
                if let data = raw.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    type = obj["type"] as? String ?? ""
                    files = obj["files"] as? [String] ?? []
                    dir = obj["dir"] as? String ?? ""
                    error = obj["error"] as? String ?? ""
                }
                self?.emit { self?.onFileTransfer?(type, files, dir, error) }
            }
            done.signal()
        }
        t.name = "filetrans-loop"
        t.start()
    }

    // MARK: - Device info (storage / model)

    /// Fetch the phone's `/base-info` (storage capacity, model, OS) on a one-shot
    /// background thread — `device_info()` is a blocking HTTP round-trip, so it must
    /// not run on `queue` (which serializes the mirror/input lifecycle) or main.
    private func fetchDeviceInfo(_ s: PcSession) {
        Thread.detachNewThread { [weak self] in
            do {
                let raw = try s.device_info().toString()
                guard let info = PhoneInfo.parse(raw) else {
                    log("device_info: unparseable payload")
                    return
                }
                if info.deviceId.isEmpty { log("device_info: no device id (older core or unresolved)") }
                self?.emit { self?.onDeviceInfo?(info) }
            } catch {
                log("device_info failed: \(ffiMessage(error))")
            }
        }
    }

    // MARK: - Disconnect detection & recovery

    /// Park a thread on the Rust liveness signal for this connection. When the
    /// control WS dies it returns a reason; we tear the dead session down and
    /// report the loss (once, for the current generation). `stop_watch()` makes it
    /// return "" on an intentional teardown, in which case we do nothing.
    private func startDisconnectWatcher(_ s: PcSession, gen: Int) {
        let done = DispatchSemaphore(value: 0)
        watchDone = done
        let t = Thread { [weak self] in
            let reason = s.wait_disconnect().toString()
            done.signal()                       // exiting → teardown's join can proceed
            guard !reason.isEmpty else { return } // stop_watch() → intentional, no recovery
            self?.queue.async {
                guard let self, self.connGen == gen, self.session != nil else { return }
                self.handleConnectionLost(reason: reason)
            }
        }
        t.name = "disconnect-watch"
        t.start()
    }

    /// An established session ended on its own. Release the dead handles and
    /// report it so the owner can decide about reconnecting. Runs on `queue`.
    private func handleConnectionLost(reason: String) {
        let device = currentDevice
        // The core's two verdicts (see `wait_disconnect` in the bridge).
        let phoneEnded = reason == "closed by phone"
        log("connection ended (\(reason))")
        teardownLocked()              // releases the dead session + stops the mirror
        connGen += 1                  // any other stale watcher/pump callback now no-ops
        emitState(.disconnected)      // a clean baseline; the owner may move to .reconnecting
        if let device { emit { self.onConnectionLost?(device, phoneEnded) } }
    }

    /// The mirror stream ended while the control session is still alive (the phone
    /// stopped the mirror service, not the whole connection). Re-open it, bounded by
    /// the same recovery budget as the black-screen watchdog. Runs on `queue`.
    private func handleStreamDropped(settings: MirrorSettings) {
        guard mirrorRecoveries < mirrorRecoverMax else {
            log("mirror stream dropped; recovery budget exhausted, leaving as-is")
            return
        }
        mirrorRecoveries += 1
        log("mirror stream dropped → restarting (attempt \(mirrorRecoveries))")
        stopMirrorLocked()
        startMirrorLocked(settings: settings)
    }

    // MARK: - Input (mouse / scroll), dispatched off the main thread

    /// action: 0=down 1=up 2=move · button: 1=left 2=right.
    func sendMouse(action: UInt8, button: UInt8, x: Int, y: Int, w: Int, h: Int) {
        if action == 2 { coalesceMove(button: button, x: x, y: y, w: w, h: h); return }
        inputQueue.async { [self] in
            guard let s = snapshotSession() else { return }
            _ = s.mouse(action, button, Int64(x), Int64(y), Int64(w), Int64(h))
        }
    }

    func sendScroll(v: Int, x: Int, y: Int, w: Int, h: Int) {
        inputQueue.async { [self] in
            guard let s = snapshotSession() else { return }
            _ = s.scroll(Int64(v), Int64(x), Int64(y), Int64(w), Int64(h))
        }
    }

    /// Press an Android navigation key (down+up). `keycode` is a `KEYCODE_*` value.
    func sendKey(_ keycode: Int) {
        inputQueue.async { [self] in
            guard let s = snapshotSession() else { return }
            _ = s.key(Int64(keycode))
        }
    }

    /// Commit typed `text` into the phone's focused input field (Unicode-safe).
    func sendText(_ text: String) {
        inputQueue.async { [self] in
            guard let s = snapshotSession() else { return }
            _ = s.text(text)
        }
    }

    /// Delete `before` chars before / `after` chars after the cursor (Backspace).
    func sendDeleteSurrounding(before: Int, after: Int) {
        inputQueue.async { [self] in
            guard let s = snapshotSession() else { return }
            _ = s.delete_surrounding(Int64(before), Int64(after))
        }
    }

    /// Drag moves can arrive far faster than the network round-trip; keep only the
    /// latest pending move so the cursor doesn't lag behind a backlog.
    private func coalesceMove(button: UInt8, x: Int, y: Int, w: Int, h: Int) {
        lock.lock()
        pendingMove = (button, x, y, w, h)
        let kick = !moveDraining
        if kick { moveDraining = true }
        lock.unlock()
        guard kick else { return }
        inputQueue.async { [self] in
            while true {
                lock.lock()
                guard let m = pendingMove else { moveDraining = false; lock.unlock(); return }
                pendingMove = nil
                lock.unlock()
                guard let s = snapshotSession() else {
                    lock.lock(); moveDraining = false; lock.unlock(); return
                }
                _ = s.mouse(2, m.0, Int64(m.1), Int64(m.2), Int64(m.3), Int64(m.4))
            }
        }
    }

    // MARK: - Helpers

    private func setSession(_ s: PcSession?) {
        session = s
        lock.lock(); sessionRef = s; lock.unlock()
    }
    private func snapshotSession() -> PcSession? {
        lock.lock(); defer { lock.unlock() }; return sessionRef
    }
    /// Claim a new connect attempt, invalidating any attempt already in flight.
    /// The old attempt's blocking FFI call is aborted too, so this one doesn't have
    /// to queue behind it; the core ignores a cancel raised before its own call
    /// began, so this can't kill the attempt we're starting.
    private func beginAttempt() -> Int {
        lock.lock(); attemptGen += 1; let gen = attemptGen; lock.unlock()
        pcsuite_cancel_connect()   // no-op unless a connect is actually in flight
        return gen
    }
    /// True once this attempt has been cancelled or superseded by a newer one.
    private func isStale(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; return attemptGen != gen
    }
    private func emitState(_ s: ConnState) { emit { self.onState?(s) } }
    private func emitMirroring(_ on: Bool, _ layer: AVSampleBufferDisplayLayer?) {
        emit { self.onMirroring?(on, layer) }
    }
    private func emit(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }
}
