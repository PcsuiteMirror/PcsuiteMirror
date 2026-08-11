import SwiftUI
import AppKit
import AVFoundation
import Combine

private let kCorner: CGFloat = 18      // screen + outer-frame corner
private let kBar: CGFloat = 34         // title-bar height (taller → easier to grab + drag)
private let kInset: CGFloat = 6        // frame margin around the screen (sides)
private let kNav: CGFloat = 38         // bottom navigation-key bar height
private let kEdgeReveal: CGFloat = 84  // pointer distance from picture top/bottom that reveals the chrome

/// Android `KeyEvent` codes for the on-screen navigation keys.
enum AndroidKey {
    static let back = 4        // KEYCODE_BACK
    static let home = 3        // KEYCODE_HOME
    static let appSwitch = 187 // KEYCODE_APP_SWITCH (recents)
}

// MARK: - Chrome bars (SwiftUI: just the buttons; bg + geometry are AppKit/CoreAnimation)

/// Published chrome progress (0 hidden → 1 shown). Set by the AppKit container; the
/// SwiftUI bars animate themselves off it. `pinned` force-shows the bars at full
/// opacity regardless of `p` (used while a lock/privacy overlay is up, so the window
/// controls stay visible without the user having to hover to reveal them).
final class ChromeProgress: ObservableObject {
    @Published var p: CGFloat = 0
    @Published var pinned: Bool = false
}

/// The title bar (top) and Android nav keys (bottom). Transparent elsewhere so the
/// frame layer and the video (behind/around it) show through.
/// Speaker-button state. Its own model (like the overlays) so the chrome view never
/// holds `AppModel` — the manager's reference to it is deliberately `unowned`, and a
/// SwiftUI `@ObservedObject` would be a strong one.
final class AudioChromeModel: ObservableObject {
    /// The phone is routing its audio here (otherwise there's nothing local to mute).
    @Published var routedToMac = false
    @Published var muted = false
}

struct MirrorChromeView: View {
    @ObservedObject var progress: ChromeProgress
    /// Observed so the icon follows a mute toggled from the menu bar too.
    @ObservedObject var audio: AudioChromeModel
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void
    let onKey: (Int) -> Void
    let onToggleMute: () -> Void

    var body: some View {
        let p = progress.pinned ? 1 : progress.p   // pinned → fully shown, ignore hover progress
        VStack(spacing: 0) {
            titleBar.opacity(Double(p)).offset(y: -(1 - p) * 6)
            Spacer(minLength: 0)
            navBar.opacity(Double(p)).offset(y: (1 - p) * 6)
        }
        .animation(.easeInOut(duration: 0.24), value: progress.p)
        .animation(.easeInOut(duration: 0.24), value: progress.pinned)
    }

    private var titleBar: some View {
        ZStack(alignment: .leading) {
            WindowDragHandle()      // drag the window from any empty title-bar spot
            HStack {
                TrafficLights(onClose: onClose, onMinimize: onMinimize, onZoom: onZoom)
                Spacer()
                // Mute this Mac. Only meaningful while the phone is routing its audio
                // here — otherwise the sound is coming out of the phone and there is
                // nothing local to silence.
                if audio.routedToMac {
                    NavKey(symbol: audio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                           action: onToggleMute)
                        .help(audio.muted ? L("Unmute this Mac") : L("Mute this Mac"))
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: kBar)
    }

    private var navBar: some View {
        HStack(spacing: 40) {
            NavKey(symbol: "chevron.left") { onKey(AndroidKey.back) }    // back
            NavKey(symbol: "circle") { onKey(AndroidKey.home) }          // home
            NavKey(symbol: "square") { onKey(AndroidKey.appSwitch) }     // recents
        }
        .frame(height: kNav)
    }
}

// MARK: - Privacy overlay (shown over the picture when the phone hits a secure screen)

/// Drives the privacy overlay. `kind` is the phone's `privacyState` token.
final class PrivacyOverlayModel: ObservableObject {
    @Published var kind: String = ""   // "" / "clear" = hidden
    var active: Bool { !kind.isEmpty && kind != "clear" }
}

/// A frosted panel covering the picture while the phone shows a secure surface
/// (fingerprint / password / lock screen). The phone stops streaming then, so
/// this replaces the frozen / black picture with a clear instruction.
///
/// The lock screen gets its own directive copy: the phone holds the stream until
/// the user unlocks and then resumes on its own, so we tell the user exactly that
/// (rather than the generic "handle on phone" line used for password/secure).
struct PrivacyOverlay: View {
    @ObservedObject var model: PrivacyOverlayModel

    private var isLock: Bool { model.kind == "lockScreen" }

    private var symbol: String {
        switch model.kind {
        case "lockScreen": return "lock.fill"
        case "password": return "rectangle.and.pencil.and.ellipsis"
        default: return "lock.shield.fill"   // "safety" / fingerprint / secure
        }
    }

    private var title: String {
        isLock ? L("手机已锁屏") : L("隐私操作请在手机端处理")
    }

    /// Secondary line (lock screen only): why nothing is happening + that it's automatic.
    private var subtitle: String? {
        isLock ? L("请在手机上解锁，投屏将自动继续") : nil
    }

    var body: some View {
        ZStack {
            if model.active {
                RoundedRectangle(cornerRadius: kCorner, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: kCorner, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                    )
                VStack(spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(28)
                .transition(.opacity)
            }
        }
        // Block stray clicks on the (frozen) picture while secure/locked. The window
        // controls aren't affected: the manager pins the chrome open while this is up,
        // and the title bar / traffic lights sit in the margins, outside this overlay.
        .allowsHitTesting(model.active)
        .animation(.easeInOut(duration: 0.2), value: model.active)
    }
}

// MARK: - Reconnect overlay (shown when the link drops mid-mirror)

/// Drives the reconnect overlay off `AppModel.mirrorLink`.
final class LinkOverlayModel: ObservableObject {
    @Published var link: MirrorLink = .live
    var active: Bool { link != .live }
}

/// A frosted panel shown over the (frozen) picture while the connection is being
/// re-established, or after it was lost and we're not reconnecting. Replaces a
/// silently frozen frame with clear feedback.
struct ReconnectOverlay: View {
    @ObservedObject var model: LinkOverlayModel

    var body: some View {
        ZStack {
            if model.active {
                RoundedRectangle(cornerRadius: kCorner, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: kCorner, style: .continuous)
                            .fill(Color.black.opacity(0.5))
                    )
                VStack(spacing: 16) {
                    if model.link == .reconnecting {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        Text(L("正在重新连接…"))
                    } else {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 40, weight: .semibold))
                        Text(L("连接已断开"))
                    }
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .multilineTextAlignment(.center)
                .padding(28)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(model.active)
        .animation(.easeInOut(duration: 0.2), value: model.active)
        .animation(.easeInOut(duration: 0.2), value: model.link)
    }
}

// MARK: - Stats HUD (FPS + PC pipeline latency, toggled in Settings)

/// Drives the FPS / latency HUD. `latencyMs` is the PC-side pipeline cost (frame
/// off the core → enqueued for display), not glass-to-glass.
final class StatsOverlayModel: ObservableObject {
    @Published var visible = false
    @Published var fps: Double = 0
    @Published var latencyMs: Double = 0
}

/// A small unobtrusive HUD in the top-left of the picture showing live FPS and the
/// render-pipeline latency. Never intercepts clicks (they pass through to the phone).
struct StatsOverlay: View {
    @ObservedObject var model: StatsOverlayModel

    var body: some View {
        ZStack {
            if model.visible {
                Text("\(Int(model.fps.rounded())) FPS · \(Int(model.latencyMs.rounded())) ms")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.2), value: model.visible)
    }
}

/// Stacks the overlays in the one overlay host: reconnect (bottom), privacy (a
/// secure screen takes precedence), and the stats HUD on top.
struct MirrorOverlays: View {
    @ObservedObject var privacy: PrivacyOverlayModel
    @ObservedObject var link: LinkOverlayModel
    @ObservedObject var stats: StatsOverlayModel

    var body: some View {
        ZStack {
            ReconnectOverlay(model: link)
            PrivacyOverlay(model: privacy)
            StatsOverlay(model: stats)
        }
    }
}

// MARK: - AppKit container (fixed window; grows a frame LAYER around a fixed screen)

/// The window's content view. The OS window is FIXED at the grown size and never resizes
/// (so the picture can't shake). The visible "window" is a rounded `frameLayer` that
/// grows outward from the screen's edges while the screen layer stays put. The shadow is
/// the REAL native window shadow: we drive the grow with a per-frame timer and call
/// `invalidateShadow()` each tick so the system re-derives its own shadow as the frame
/// grows — no hand-drawn shadow.
final class MirrorContainerView: NSView {
    let video: MirrorInputView
    private let chromeHost: NSView
    private let overlayHost: NSView
    private let chromeProgress: ChromeProgress
    private let frameLayer = CALayer()

    /// No-chrome screen size (the picture's fixed pixel size).
    private(set) var screenSize: CGSize = .zero
    private(set) var progress: CGFloat = 0
    var onHover: ((Bool) -> Void)?
    /// Files dropped anywhere on the window (PC→phone push).
    var onDropFiles: (([URL]) -> Void)?
    private var tracking: NSTrackingArea?
    private var shadowTimer: Timer?   // refreshes the native shadow while the CA grow runs

    init(video: MirrorInputView, chromeHost: NSView, overlayHost: NSView, progress: ChromeProgress) {
        self.video = video
        self.chromeHost = chromeHost
        self.overlayHost = overlayHost
        self.chromeProgress = progress
        super.init(frame: .zero)
        wantsLayer = true
        frameLayer.backgroundColor = NSColor.windowBackgroundColor.cgColor
        frameLayer.cornerRadius = kCorner
        frameLayer.cornerCurve = .continuous
        layer?.addSublayer(frameLayer)         // behind the subviews
        addSubview(chromeHost)                 // bars (in the margins)
        addSubview(video)                      // the picture (centre)
        overlayHost.wantsLayer = true
        addSubview(overlayHost)                // privacy overlay, above the picture
        registerForDraggedTypes([.fileURL])    // drop files → push to the phone
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: File drop (PC→phone push)

    /// Accent border around the frame while a file drag hovers, so the drop
    /// target reads as armed.
    private func setDropHighlight(_ on: Bool) {
        withoutImplicitAnimation {
            frameLayer.borderWidth = on ? 3 : 0
            frameLayer.borderColor = on ? NSColor.controlAccentColor.cgColor : nil
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        setDropHighlight(true)
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { setDropHighlight(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setDropHighlight(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlight(false)
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    /// Set the fixed screen size and lay everything out for the current progress.
    func configure(screenSize: CGSize) {
        self.screenSize = screenSize
        layoutContent()
        applyFrameLayer()
        window?.invalidateShadow()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with e: NSEvent) { updateReveal(e) }
    override func mouseMoved(with e: NSEvent) { updateReveal(e) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }

    /// Reveal the chrome only when the pointer is near the picture's top or bottom
    /// edge (video-player style), not on any hover over the window.
    private func updateReveal(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)   // container coords (bottom-left)
        let f = video.frame
        let nearEdge = p.y <= f.minY + kEdgeReveal || p.y >= f.maxY - kEdgeReveal
        onHover?(nearEdge)
    }

    /// Grow/shrink the frame layer (the picture stays fixed). The grow itself runs on
    /// the render server via Core Animation — vsync-synced and OFF the main thread — so
    /// a busy main thread (60 fps decode) can never make it stutter. The only main-
    /// thread work left is re-deriving the native window shadow as the frame grows; we
    /// do that on a light ~30 Hz timer for the animation's duration. A shadow that lags
    /// a frame or two is imperceptible; a stuttering frame is not.
    private let growDuration: CFTimeInterval = 0.24

    func setProgress(_ p: CGFloat, animated: Bool) {
        // mouseMoved fires continuously while the pointer is in the reveal zone, so
        // onHover calls this many times/sec with the SAME target. Re-adding the CA
        // animation each time restarts the curve every frame → it never settles and
        // reads as a stutter. Ignore no-op calls; only act on a real state change.
        guard p != progress else { return }
        shadowTimer?.invalidate(); shadowTimer = nil
        chromeProgress.p = p   // SwiftUI bars animate off this (its own .animation)
        progress = p

        let target = frameRect(for: p)
        let targetSize = target.size
        let targetPos = CGPoint(x: target.midX, y: target.midY)   // frameLayer anchor = (0.5,0.5)

        guard animated else {
            withoutImplicitAnimation {
                frameLayer.removeAnimation(forKey: "grow")
                frameLayer.bounds = CGRect(origin: .zero, size: targetSize)
                frameLayer.position = targetPos
            }
            window?.invalidateShadow()
            return
        }

        // Start from whatever is currently on screen so an interrupted reveal flows
        // instead of jumping, then set the model to its final value and let an explicit
        // CA animation interpolate the presentation.
        let pres = frameLayer.presentation()
        let fromSize = pres?.bounds.size ?? frameLayer.bounds.size
        let fromPos = pres?.position ?? frameLayer.position
        withoutImplicitAnimation {
            frameLayer.bounds = CGRect(origin: .zero, size: targetSize)
            frameLayer.position = targetPos
        }
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        let sizeAnim = CABasicAnimation(keyPath: "bounds.size")
        sizeAnim.fromValue = NSValue(size: fromSize)
        sizeAnim.toValue = NSValue(size: targetSize)
        let posAnim = CABasicAnimation(keyPath: "position")
        posAnim.fromValue = NSValue(point: fromPos)
        posAnim.toValue = NSValue(point: targetPos)
        let group = CAAnimationGroup()
        group.animations = [sizeAnim, posAnim]
        group.duration = growDuration
        group.timingFunction = timing
        frameLayer.add(group, forKey: "grow")

        // Track the native shadow to the growing frame at ~30 Hz for the duration.
        window?.invalidateShadow()
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.window?.invalidateShadow()
            if Date().timeIntervalSince(start) >= self.growDuration {
                t.invalidate(); self.shadowTimer = nil
                self.window?.invalidateShadow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        shadowTimer = timer
    }

    override func layout() {
        super.layout()
        layoutContent()
        applyFrameLayer()
    }

    private func layoutContent() {
        chromeHost.frame = bounds
        withoutImplicitAnimation {
            // With a known picture size the video sits in the chrome margins; without
            // one (no frames yet — e.g. the phone is locked and streaming nothing) we
            // still inset by the margins instead of filling `bounds`, so the privacy /
            // lock overlay never covers the title bar and the window controls stay
            // reachable above it.
            let videoRect = screenSize.width > 1
                ? NSRect(x: kInset, y: kNav, width: screenSize.width, height: screenSize.height)
                : NSRect(x: kInset, y: kNav,
                         width: max(0, bounds.width - 2 * kInset),
                         height: max(0, bounds.height - kBar - kNav))
            video.frame = videoRect
            overlayHost.frame = videoRect   // privacy panel covers the picture
        }
    }

    private func applyFrameLayer() {
        withoutImplicitAnimation { frameLayer.frame = frameRect(for: progress) }
    }

    /// Frame layer's rect at progress `p`: the screen rect at p=0 (only the floating
    /// screen shows) growing to the whole window at p=1 (full chrome margins).
    private func frameRect(for p: CGFloat) -> NSRect {
        guard screenSize.width > 1 else { return bounds }
        return NSRect(
            x: kInset * (1 - p),
            y: kNav * (1 - p),
            width: screenSize.width + 2 * kInset * p,
            height: screenSize.height + (kBar + kNav) * p
        )
    }

    private func withoutImplicitAnimation(_ body: () -> Void) {
        CATransaction.begin(); CATransaction.setDisableActions(true); body(); CATransaction.commit()
    }
}

// MARK: - macOS window controls

/// macOS-style window controls (close / minimize / zoom) for a borderless window.
/// Glyphs appear while the cluster is hovered, like the system.
struct TrafficLights: View {
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            light(Color(red: 1.0, green: 0.37, blue: 0.34), "xmark", onClose)
            light(Color(red: 0.99, green: 0.74, blue: 0.18), "minus", onMinimize)
            light(Color(red: 0.16, green: 0.78, blue: 0.25), "plus", onZoom)
        }
        .onHover { hovering = $0 }
    }

    private func light(_ color: Color, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                    .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                if hovering {
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.black.opacity(0.55))
                }
            }
            .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
    }
}

/// One Android navigation key (back / home / recents) for the bottom bar.
struct NavKey: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 40, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.primary.opacity(hovering ? 0.12 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Transparent AppKit view that starts a window drag on mouse-down.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ v: NSView, context: Context) {}
    final class DragView: NSView {
        override func mouseDown(with e: NSEvent) { window?.performDrag(with: e) }
    }
}

// MARK: - Video surface (AppKit)

/// NSView that draws the display layer (rounded) and maps mouse events into the phone's
/// reference frame. Positioned (fixed) by `MirrorContainerView`.
final class MirrorInputView: NSView {
    private(set) var hostedLayer: AVSampleBufferDisplayLayer
    private let maskLayer = CAShapeLayer()
    var videoSize: CGSize = .zero
    var onMouse: ((UInt8, UInt8, Int, Int, Int, Int) -> Void)?
    var onScroll: ((Int, Int, Int, Int, Int) -> Void)?
    /// Committed Unicode text from the keyboard (IME `commitText` on the phone).
    var onText: ((String) -> Void)?
    /// A special key as an Android `KEYCODE_*` value (Enter/Tab/arrows/Esc).
    var onKeyCode: ((Int) -> Void)?
    /// Backspace (delete one char before the cursor).
    var onBackspace: (() -> Void)?
    /// Phone caret position (mirror pixel space, top-left origin) for the IME;
    /// nil falls back to the pointer location.
    var imeAnchorVideo: CGPoint?
    /// Whether the phone currently has a focused text field. The keyboard only
    /// types to the phone while this is true.
    var phoneInputActive = false
    /// Whether a privacy/lock overlay is covering the picture. While it is, the picture
    /// isn't interactive (the overlay eats mouse events), so we stop hiding the system
    /// arrow behind the touch disc — otherwise the pointer would vanish over the prompt.
    var overlayActive = false {
        didSet {
            guard overlayActive != oldValue else { return }
            if overlayActive { cursorLayer.isHidden = true }   // drop the (now-stale) touch disc
            window?.invalidateCursorRects(for: self)
        }
    }

    // Touch-style pointer: the system arrow is hidden over the picture and replaced
    // by a soft translucent disc that follows the pointer and ripples on click.
    private let cursorLayer = CALayer()
    private var tracking: NSTrackingArea?
    private var scrollAccum: CGFloat = 0   // trackpad scroll accumulator (points)
    private var lastPoint: CGPoint = .zero // last pointer location (anchors the IME)

    init(_ l: AVSampleBufferDisplayLayer) {
        hostedLayer = l
        super.init(frame: .zero)
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        // Round the video itself: AVSampleBufferDisplayLayer composites video on the GPU
        // and ignores the parent's cornerRadius mask, so rounding it directly + a shape
        // mask on the root are what actually clip the picture to rounded corners.
        Self.round(l)
        root.addSublayer(l)
        Self.styleCursor(cursorLayer)
        root.addSublayer(cursorLayer)
        root.mask = maskLayer
        layer = root
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: Touch-style cursor

    private static let cursorSize: CGFloat = 24

    /// A dual-tone disc that stays visible on any background: a dark outer ring
    /// (reads on light/white screens) wrapping a bright inner ring + faint fill
    /// (reads on dark screens), plus a soft shadow for separation.
    private static func styleCursor(_ c: CALayer) {
        let s = cursorSize
        c.bounds = CGRect(x: 0, y: 0, width: s, height: s)
        c.backgroundColor = NSColor.clear.cgColor
        c.zPosition = 100          // stays above any later-added video layer
        c.isHidden = true

        let inner = CGRect(x: 2, y: 2, width: s - 4, height: s - 4)

        let fill = CALayer()
        fill.frame = inner
        fill.cornerRadius = inner.width / 2
        fill.backgroundColor = NSColor(white: 0.5, alpha: 0.22).cgColor
        c.addSublayer(fill)

        let dark = CALayer()           // dark outer ring → visible on light bg
        dark.frame = c.bounds
        dark.cornerRadius = s / 2
        dark.borderColor = NSColor.black.withAlphaComponent(0.55).cgColor
        dark.borderWidth = 3
        dark.shadowColor = NSColor.black.cgColor
        dark.shadowOpacity = 0.35
        dark.shadowRadius = 3
        dark.shadowOffset = .zero
        c.addSublayer(dark)

        let light = CALayer()          // bright inner ring → visible on dark bg
        light.frame = inner
        light.cornerRadius = inner.width / 2
        light.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
        light.borderWidth = 2
        c.addSublayer(light)
    }

    /// A fully transparent cursor so only our drawn disc shows over the picture.
    private static let blankCursor: NSCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    override func resetCursorRects() {
        if overlayActive { return }   // overlay up → let the normal system arrow show
        addCursorRect(bounds, cursor: Self.blankCursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with e: NSEvent) { cursorLayer.isHidden = false; moveCursor(e) }
    override func mouseExited(with e: NSEvent) { cursorLayer.isHidden = true }
    override func mouseMoved(with e: NSEvent) { moveCursor(e) }

    /// When `clamp` is true the disc is pulled to the nearest picture edge instead of
    /// following the raw pointer — used while a drag is held outside the screen.
    private func moveCursor(_ e: NSEvent, clamp: Bool = false) {
        var p = loc(e)
        if clamp, let rect = fitRect() {
            p.x = min(max(p.x, rect.minX), rect.maxX)
            p.y = min(max(p.y, rect.minY), rect.maxY)
        }
        lastPoint = p
        withoutImplicitAnimation {
            cursorLayer.position = p
            cursorLayer.isHidden = false
        }
    }

    private func withoutImplicitAnimation(_ body: () -> Void) {
        CATransaction.begin(); CATransaction.setDisableActions(true); body(); CATransaction.commit()
    }

    /// A quick press feedback: the disc shrinks-then-settles and an expanding ring
    /// fades out from the touch point.
    private func tapFeedback(at p: CGPoint) {
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.62; pop.toValue = 1.0; pop.duration = 0.35
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        cursorLayer.add(pop, forKey: "tap")

        let ring = CALayer()
        ring.frame = CGRect(x: 0, y: 0, width: Self.cursorSize, height: Self.cursorSize)
        ring.position = p
        ring.cornerRadius = Self.cursorSize / 2
        ring.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        ring.borderWidth = 2
        ring.zPosition = 99
        layer?.addSublayer(ring)
        let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 0.7; grow.toValue = 2.3
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.9; fade.toValue = 0
        let g = CAAnimationGroup(); g.animations = [grow, fade]; g.duration = 0.42
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(g, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak ring] in ring?.removeFromSuperlayer() }
    }

    private static func round(_ l: CALayer) {
        l.cornerRadius = kCorner
        l.cornerCurve = .continuous
        l.masksToBounds = true
    }

    func setLayer(_ l: AVSampleBufferDisplayLayer) {
        hostedLayer.removeFromSuperlayer()
        Self.round(l)
        hostedLayer = l
        layer?.addSublayer(l)
        // Keep the touch cursor above the freshly added video layer.
        cursorLayer.removeFromSuperlayer()
        layer?.addSublayer(cursorLayer)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hostedLayer.frame = bounds
        maskLayer.frame = bounds
        maskLayer.path = CGPath(roundedRect: bounds, cornerWidth: kCorner, cornerHeight: kCorner, transform: nil)
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Map a point (view coords, bottom-left origin) into the aspect-fit video rect,
    /// then to phone pixel coords (top-left origin). nil if on the letterbox.
    /// The aspect-fit rectangle (view coords) where the picture is actually drawn.
    private func fitRect() -> CGRect? {
        guard videoSize.width > 0, videoSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let vidAR = videoSize.width / videoSize.height
        let viewAR = bounds.width / bounds.height
        if vidAR > viewAR {
            let h = bounds.width / vidAR
            return CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        } else {
            let w = bounds.height * vidAR
            return CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
        }
    }

    /// When `clamp` is true, points outside the picture are pulled to the nearest edge
    /// instead of rejected — so an in-progress drag/release that left the screen still
    /// maps to a valid phone coordinate and reaches the phone.
    private func map(_ p: CGPoint, clamp: Bool = false) -> (Int, Int, Int, Int)? {
        guard let rect = fitRect() else { return nil }
        var nx = (p.x - rect.minX) / rect.width
        var ny = (p.y - rect.minY) / rect.height
        if clamp {
            nx = min(max(nx, 0), 1)
            ny = min(max(ny, 0), 1)
        } else if !rect.contains(p) {
            return nil
        }
        let vx = Int((nx * videoSize.width).rounded())
        let vy = Int(((1 - ny) * videoSize.height).rounded()) // flip y to top-left origin
        return (vx, vy, Int(videoSize.width), Int(videoSize.height))
    }

    /// Inverse of `map`: a phone caret point (mirror px, top-left) → view point.
    private func videoToView(_ p: CGPoint) -> CGPoint? {
        guard let rect = fitRect() else { return nil }
        let fx = min(max(p.x / videoSize.width, 0), 1)
        let fy = min(max(p.y / videoSize.height, 0), 1)
        return CGPoint(x: rect.minX + fx * rect.width,
                       y: rect.minY + (1 - fy) * rect.height) // flip y to bottom-left
    }

    private func loc(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseDown(with e: NSEvent) { trackDrag(e, button: 1) }
    override func rightMouseDown(with e: NSEvent) { trackDrag(e, button: 2) }

    /// Drive a whole press→drag→release as a modal mouse-tracking loop. A drag that
    /// leaves this small borderless window otherwise stops getting `mouseDragged`/
    /// `mouseUp` delivered to the view — so the release never reaches the phone and the
    /// gesture freezes (page stuck mid-swipe). Pulling the events from the app queue
    /// ourselves guarantees we see every move and the release no matter where the
    /// pointer is, clamp them to the screen edge, and always send the touch-up so the
    /// phone completes the gesture.
    private func trackDrag(_ down: NSEvent, button: UInt8) {
        moveCursor(down)
        guard let m = map(loc(down)) else { return }   // press on the letterbox → no touch
        if button == 1 { tapFeedback(at: loc(down)) }
        onMouse?(0, button, m.0, m.1, m.2, m.3)

        let mask: NSEvent.EventTypeMask = button == 1
            ? [.leftMouseDragged, .leftMouseUp]
            : [.rightMouseDragged, .rightMouseUp]
        let upType: NSEvent.EventType = button == 1 ? .leftMouseUp : .rightMouseUp

        while let ev = NSApp.nextEvent(matching: mask, until: .distantFuture,
                                       inMode: .eventTracking, dequeue: true) {
            let up = ev.type == upType
            moveCursor(ev, clamp: true)
            if let p = map(loc(ev), clamp: true) { onMouse?(up ? 1 : 2, button, p.0, p.1, p.2, p.3) }
            if up { break }
        }
    }

    /// Trackpad scrolling is far finer-grained than a wheel notch — emitting one
    /// phone scroll per event makes it hyper-sensitive. Accumulate the precise
    /// delta and emit a tick only once it crosses a threshold; a wheel mouse
    /// (coarse, line-based deltas) still emits one tick per notch.
    override func scrollWheel(with e: NSEvent) {
        guard let m = map(loc(e)) else { return }
        if e.hasPreciseScrollingDeltas {
            scrollAccum += e.scrollingDeltaY
            let threshold: CGFloat = 22   // points of finger travel per phone scroll tick
            while abs(scrollAccum) >= threshold {
                let dir = scrollAccum > 0 ? 1 : -1
                onScroll?(dir, m.0, m.1, m.2, m.3)
                scrollAccum -= CGFloat(dir) * threshold
            }
            if e.phase == .ended || e.phase == .cancelled || e.momentumPhase == .ended {
                scrollAccum = 0
            }
        } else if e.scrollingDeltaY != 0 {
            onScroll?(e.scrollingDeltaY > 0 ? 1 : -1, m.0, m.1, m.2, m.3)
        }
    }

    // MARK: Keyboard → phone

    // Pinyin/kana/etc. in-progress composition (shown in the macOS candidate
    // window; nothing is sent to the phone until the IME commits final text).
    private var markedText = ""

    override func keyDown(with e: NSEvent) {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Leave ⌘/⌃ chords to the system (menu shortcuts, etc.); don't beep.
        if flags.contains(.command) || flags.contains(.control) { return }
        // Type only when the phone is in input mode (a field is focused);
        // otherwise swallow the key so stray typing never reaches the phone.
        guard phoneInputActive else { return }

        // While composing (IME candidate up), every key belongs to the IME.
        if !hasMarkedText() {
            // Special keys → Android KEYCODE_* (so they act like hardware keys).
            switch e.keyCode {
            case 51:        onBackspace?(); return              // Delete (backspace)
            case 36, 76:    onKeyCode?(66); return              // Return / Enter → ENTER
            case 48:        onKeyCode?(61); return              // Tab → TAB
            case 53:        onKeyCode?(4);  return              // Esc → BACK
            case 117:       onKeyCode?(112); return             // Fwd Delete → FORWARD_DEL
            case 123:       onKeyCode?(21); return              // ← DPAD_LEFT
            case 124:       onKeyCode?(22); return              // → DPAD_RIGHT
            case 125:       onKeyCode?(20); return              // ↓ DPAD_DOWN
            case 126:       onKeyCode?(19); return              // ↑ DPAD_UP
            default: break
            }
        }
        // Route through the active input method: latin keys arrive via
        // insertText, CJK/emoji composition via setMarkedText then insertText.
        _ = inputContext?.handleEvent(e)
    }

    // Consume key-ups so they don't ring the system bell at the responder chain end.
    override func keyUp(with e: NSEvent) {}

    // Swallow editing selectors the IME emits for keys we don't model, so the
    // responder chain doesn't end in a system beep.
    override func doCommand(by selector: Selector) {}
}

// MARK: - IME text input (so Chinese / Japanese / emoji compose correctly)

extension MirrorInputView: NSTextInputClient {
    private func asString(_ any: Any) -> String {
        (any as? String) ?? (any as? NSAttributedString)?.string ?? ""
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = ""
        let s = asString(string)
        if !s.isEmpty { onText?(s) }   // committed text → commit on the phone
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = asString(string)   // still composing; not sent yet
    }

    func unmarkText() { markedText = "" }
    func hasMarkedText() -> Bool { !markedText.isEmpty }
    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
                           : NSRange(location: 0, length: markedText.utf16.count)
    }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// Anchor the IME candidate window at the phone's reported caret (mapped into
    /// view coords); fall back to the last tap location if no caret is known.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let w = window else { return .zero }
        let p: CGPoint
        if let a = imeAnchorVideo, let v = videoToView(a) {
            p = v
        } else {
            p = (lastPoint == .zero) ? CGPoint(x: bounds.midX, y: bounds.midY) : lastPoint
        }
        let inWindow = convert(p, to: nil)
        return w.convertToScreen(NSRect(origin: inWindow, size: CGSize(width: 1, height: 1)))
    }
}

/// Borderless window that can still become key (so mouse/keyboard reach the content).
final class MirrorPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Window manager

/// Owns the mirror window. Showing it starts mirroring; closing it stops mirroring.
final class MirrorWindowManager: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private var window: NSWindow?
    private var container: MirrorContainerView?
    private var video: MirrorInputView?
    private let chromeProgress = ChromeProgress()
    private let privacyOverlay = PrivacyOverlayModel()
    private let linkOverlay = LinkOverlayModel()
    private let statsOverlay = StatsOverlayModel()
    private let audioChrome = AudioChromeModel()
    private var bag = Set<AnyCancellable>()
    private var baseScreenH: CGFloat = 640   // screen height in points; window = screen + chrome
    /// While a privacy/lock overlay is up, the window chrome is force-revealed and
    /// held (the hover-to-reveal is unreliable under a full-picture overlay), so the
    /// user can always reach close / move while the (possibly long-lived) prompt is up.
    private var chromePinned = false

    init(model: AppModel) { self.model = model }

    /// Whether the mirror window is currently open (used to decide whether to resume
    /// mirroring after an auto-reconnect, and whether to show the reconnect overlay).
    var isShowing: Bool { window != nil }

    func show(connect: Bool = true) {
        NSApp.setActivationPolicy(.regular)  // Dock icon + Cmd-Tab while the mirror is up
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // The window is fixed at the GROWN size (screen + chrome margins). It never
        // resizes; the chrome animates within it (native shadow follows via per-frame
        // invalidateShadow).
        let w = MirrorPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: baseScreenH + kBar + kNav),
            // `.miniaturizable` is required even though we draw our own traffic
            // lights: AppKit ignores miniaturize() on a borderless window without it
            // (verified — with the flag it works, without it nothing happens).
            styleMask: [.borderless, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        let placeholder = model.displayLayer ?? AVSampleBufferDisplayLayer()
        let video = MirrorInputView(placeholder)
        video.videoSize = model.videoSize
        video.onMouse = { [weak self] a, b, x, y, w, h in self?.model.mouse(action: a, button: b, x: x, y: y, w: w, h: h) }
        video.onScroll = { [weak self] v, x, y, w, h in self?.model.scroll(v: v, x: x, y: y, w: w, h: h) }
        video.onText = { [weak self] s in self?.model.typeText(s) }
        video.onKeyCode = { [weak self] code in self?.model.key(code) }
        video.onBackspace = { [weak self] in self?.model.backspace() }

        let chromeHost = NSHostingView(rootView: MirrorChromeView(
            progress: chromeProgress,
            audio: audioChrome,
            onClose: { [weak self] in self?.model.closeMirror() },
            onMinimize: { [weak self] in self?.window?.miniaturize(nil) },
            onZoom: { [weak self] in self?.toggleZoom() },
            onKey: { [weak self] code in self?.model.key(code) },
            onToggleMute: { [weak self] in self?.model.toggleAudioMuted() }
        ))

        let overlayHost = NSHostingView(rootView: MirrorOverlays(privacy: privacyOverlay, link: linkOverlay, stats: statsOverlay))
        overlayHost.layer?.backgroundColor = .clear

        let container = MirrorContainerView(video: video, chromeHost: chromeHost, overlayHost: overlayHost, progress: chromeProgress)
        container.onHover = { [weak self] hovering in
            guard let self, !self.chromePinned else { return }   // pinned: ignore hover, stay revealed
            self.container?.setProgress(hovering ? 1 : 0, animated: true)
        }
        container.onDropFiles = { [weak self] urls in self?.model.pushFiles(urls) }

        w.contentView = container
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true    // real native shadow; we invalidate it per-frame as the frame grows
        w.acceptsMouseMovedEvents = true   // so the touch-style cursor can follow the pointer
        w.isMovableByWindowBackground = false
        w.minSize = NSSize(width: 240, height: 420)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()

        window = w
        self.container = container
        self.video = video

        model.$displayLayer
            .receive(on: RunLoop.main)
            .sink { [weak self] layer in
                guard let self, let layer, let v = self.video, v.hostedLayer !== layer else { return }
                v.setLayer(layer)
            }.store(in: &bag)
        model.$videoSize
            .receive(on: RunLoop.main)
            .sink { [weak self] sz in self?.applyAspect(sz) }
            .store(in: &bag)
        // The overlay/chrome reflect BOTH the keyguard lock and the foreground-window
        // privacy state; the lock takes precedence (its own prompt). Recompute on any
        // change to either.
        model.$privacyState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshPrivacyChrome() }
            .store(in: &bag)
        model.$screenLocked
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshPrivacyChrome() }
            .store(in: &bag)
        model.$mirrorLink
            .receive(on: RunLoop.main)
            .sink { [weak self] link in self?.linkOverlay.link = link }
            .store(in: &bag)
        model.$showStats
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.statsOverlay.visible = on }
            .store(in: &bag)
        model.$audioEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.audioChrome.routedToMac = on }
            .store(in: &bag)
        model.$audioMuted
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.audioChrome.muted = on }
            .store(in: &bag)
        // Per-second HUD stats. A closure, not a @Published subscription: publishing
        // these on the model rebuilds the menu-bar dropdown every second.
        model.mirrorStatsSink = { [weak self] fps, lat in
            self?.statsOverlay.fps = fps
            self?.statsOverlay.latencyMs = lat
        }
        // Phone caret → place the IME there (mapped to view coords in firstRect).
        model.imeCursorSink = { [weak self] p in self?.video?.imeAnchorVideo = p }
        // Phone input mode → gate the keyboard (only type when a field is focused).
        model.imeActiveSink = { [weak self] on in self?.video?.phoneInputActive = on }

        applyAspect(model.videoSize)
        if connect { model.startMirror() }
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(video)   // keyboard goes to the picture
        NSApp.activate(ignoringOtherApps: true)
        log("mirror window number: \(w.windowNumber)")
    }

    func close() { window?.close() }

    /// Recompute the privacy/lock overlay + chrome from the model. The keyguard lock
    /// takes precedence over foreground-window privacy (its own "please unlock" prompt).
    /// While either is active the chrome is pinned open so the window controls stay
    /// reachable without hovering (`pinned` force-shows the bars; `setProgress(1)` grows
    /// the frame so they sit on the opaque chrome backing, not a transparent margin).
    private func refreshPrivacyChrome() {
        privacyOverlay.kind = model.screenLocked ? "lockScreen" : model.privacyState
        let active = privacyOverlay.active
        video?.overlayActive = active   // show the system arrow over the prompt (picture isn't interactive)
        chromeProgress.pinned = active
        if active != chromePinned {
            chromePinned = active
            container?.setProgress(active ? 1 : 0, animated: true)
        }
    }

    /// Fit the window (fixed size) to the phone's aspect ratio: screen = baseScreenH tall,
    /// window = screen + chrome margins. Repositions the picture + frame layer.
    private func applyAspect(_ sz: CGSize) {
        guard let w = window, let container = container, sz.width > 0, sz.height > 0 else { return }
        let screenH = baseScreenH
        let screenW = (screenH * sz.width / sz.height).rounded()
        video?.videoSize = sz
        let newSize = NSSize(width: screenW + 2 * kInset, height: screenH + kBar + kNav)
        if abs(w.frame.width - newSize.width) > 0.5 || abs(w.frame.height - newSize.height) > 0.5 {
            w.setContentSize(newSize)
        }
        container.configure(screenSize: CGSize(width: screenW, height: screenH))
    }

    /// Height to restore when un-zooming; non-nil only while zoomed.
    private var unzoomedScreenH: CGFloat?

    /// Grow the mirror to fill the screen's height, or restore the previous size.
    ///
    /// `NSWindow.zoom(_:)` is useless here: the window's size is derived from
    /// `baseScreenH` through `applyAspect` (the picture is a fixed pixel size the
    /// chrome grows around), so a frame AppKit picks on its own leaves the content
    /// behind. Driving the same path that every other resize uses keeps the phone
    /// aspect exact and the picture correctly laid out.
    func toggleZoom() {
        guard let w = window, model.videoSize.width > 0 else { return }
        let visible = (w.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        if let restore = unzoomedScreenH {
            baseScreenH = restore
            unzoomedScreenH = nil
        } else {
            unzoomedScreenH = baseScreenH
            baseScreenH = max(320, visible.height - kBar - kNav - 16)
        }
        applyAspect(model.videoSize)
        // setContentSize keeps the bottom-left corner, so a grown window can run off
        // the top of the screen. Nudge it back inside.
        var f = w.frame
        f.origin.x = min(max(f.origin.x, visible.minX), max(visible.maxX - f.width, visible.minX))
        f.origin.y = min(max(f.origin.y, visible.minY), max(visible.maxY - f.height, visible.minY))
        if f.origin != w.frame.origin { w.setFrameOrigin(f.origin) }
    }

    /// Test hook (=2): jump to the hovered/grown state.
    func testForceHover() { container?.setProgress(1, animated: false) }

    /// Test hook (=5): put the window on the active Space at a known spot, leave at rest.
    func testPosition() {
        window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window?.setFrameOrigin(NSPoint(x: 120, y: 200))
    }

    /// Test hook (=3): toggle the hover animation forever for a screen recording.
    private var testTimer: Timer?
    func testAutoToggle() {
        window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window?.setFrameOrigin(NSPoint(x: 120, y: 200))
        var on = false
        testTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            on.toggle()
            self?.container?.setProgress(on ? 1 : 0, animated: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        testTimer?.invalidate(); testTimer = nil
        bag.removeAll()
        model.imeCursorSink = nil
        model.imeActiveSink = nil
        model.mirrorStatsSink = nil
        model.stopMirror()
        window = nil; container = nil; video = nil
        chromePinned = false
        chromeProgress.pinned = false
        NSApp.setActivationPolicy(.accessory) // back to menu-bar agent
    }
}
