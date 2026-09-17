import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Drop files on the menu-bar icon to send them to a phone, the way Tailscale's
// icon takes files: dragging over the icon opens a panel of remembered phones
// under it, and dropping on one sends there (connecting first if needed).
// Releasing on the icon itself sends straight to the connected phone; with none
// connected the panel stays open holding the files until one is clicked.
//
// `MenuBarExtra` exposes no drop API, so we find its status-bar button and lay a
// transparent view over it that takes drags but lets clicks through.

final class StatusItemDrop {
    static let shared = StatusItemDrop()

    private weak var model: AppModel?
    private var overlay: StatusDropView?
    private var panel: NSPanel?
    private let panelState = DropPanelState()
    private var releaseWatch: Timer?
    private var outsideClickMonitor: Any?

    /// Attach to the status item once it exists (it appears after the scene is built).
    func install(model: AppModel, attempt: Int = 0) {
        self.model = model
        guard overlay == nil else { return }
        guard let button = Self.statusButton() else {
            if attempt < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.install(model: model, attempt: attempt + 1)
                }
            } else {
                log("status item drop: no status bar button found — drop to icon disabled")
            }
            return
        }
        let view = StatusDropView(frame: button.bounds)
        view.autoresizingMask = [.width, .height]
        view.owner = self
        button.addSubview(view)
        overlay = view
        log("status item drop: installed")
    }

    /// Our status item's button: the only `NSStatusBarButton` in this process's
    /// status-bar windows.
    private static func statusButton() -> NSStatusBarButton? {
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBar") {
            if let button = find(NSStatusBarButton.self, in: window.contentView) { return button }
        }
        return nil
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let hit = view as? T { return hit }
        for sub in view.subviews {
            if let hit = find(type, in: sub) { return hit }
        }
        return nil
    }

    // MARK: Drag over the icon

    func dragEntered() {
        panelState.pending = []
        showPanel()
        watchForRelease()
    }

    /// Files released on the icon itself.
    func dropOnIcon(_ urls: [URL]) {
        guard let model, !urls.isEmpty else { return }
        if model.isConnected {
            model.pushFiles(urls)
            closePanel()
        } else {
            panelState.pending = urls
            showPanel()
        }
    }

    /// Files dropped on (or pending files sent to) one row of the panel.
    func send(_ urls: [URL], to target: DropTarget) {
        guard let model, !urls.isEmpty else { return }
        switch target {
        case .current: model.pushFiles(urls)
        case .device(let dev): model.sendFiles(urls, to: dev)
        }
        closePanel()
    }

    // MARK: Panel

    private func showPanel() {
        guard let model, let button = overlay?.superview, let buttonWindow = button.window else { return }
        if panel == nil {
            let p = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
            p.isFloatingPanel = true
            p.level = .popUpMenu
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 12
            effect.layer?.masksToBounds = true
            let host = NSHostingView(rootView: DropPanelView(model: model, state: panelState, owner: self))
            host.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                host.topAnchor.constraint(equalTo: effect.topAnchor),
                host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            p.contentView = effect
            panel = p
        }
        guard let panel, let host = panel.contentView?.subviews.first else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let icon = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(x: icon.midX - size.width / 2, y: icon.minY - size.height - 6)
        if let screen = buttonWindow.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()

        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                // A click anywhere else dismisses it, like a popover. Not while a
                // drag is still arriving — its mouse-down happened elsewhere first.
                guard let self, self.releaseWatch == nil else { return }
                self.closePanel()
            }
        }
    }

    func closePanel() {
        releaseWatch?.invalidate()
        releaseWatch = nil
        panelState.pending = []
        panel?.orderOut(nil)
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }

    /// A drag that ends anywhere but the icon or a row (released elsewhere, or
    /// cancelled) should take the panel away with it. The drag's own callbacks
    /// don't reach us when it ends outside our views, so watch the mouse button.
    private func watchForRelease() {
        releaseWatch?.invalidate()
        releaseWatch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            // Give a drop on the icon or a row its turn to run first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let self else { return }
                self.releaseWatch = nil
                if self.panelState.pending.isEmpty { self.closePanel() }
            }
        }
    }
}

/// What a panel row sends to.
enum DropTarget {
    /// The connected phone (it may not be in the roster yet).
    case current
    case device(KnownDevice)
}

final class DropPanelState: ObservableObject {
    /// Files released on the icon, waiting for a phone to be picked.
    @Published var pending: [URL] = []
}

/// Transparent drop target over the status-bar button. Clicks pass through to the
/// button underneath; only drags stop here.
final class StatusDropView: NSView {
    weak var owner: StatusItemDrop?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // A click (or a hover) must reach the button so its menu still opens.
        // Drag lookups happen while no mouse event of ours is being handled.
        if let event = NSApp.currentEvent,
           ProcessInfo.processInfo.systemUptime - event.timestamp < 1 {
            switch event.type {
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                 .otherMouseDown, .otherMouseUp, .mouseMoved, .mouseEntered, .mouseExited:
                return nil
            default: break
            }
        }
        return super.hitTest(point)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.fileURLs(sender).isEmpty == false else { return [] }
        owner?.dragEntered()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(sender)
        guard !urls.isEmpty else { return false }
        owner?.dropOnIcon(urls)
        return true
    }

    private static func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

// MARK: - Panel content

private struct DropPanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: DropPanelState
    let owner: StatusItemDrop

    /// The connected phone, when it has no roster row yet.
    private var unlistedCurrent: String? {
        guard model.isConnected, let cur = model.lastDevice,
              !model.knownDevices.contains(where: { $0.id == model.activeDeviceId }) else { return nil }
        return cur.displayName
    }

    private var connected: KnownDevice? {
        guard model.isConnected else { return nil }
        return model.knownDevices.first { $0.id == model.activeDeviceId }
    }

    private var others: [KnownDevice] {
        model.knownDevices.filter { $0.id != connected?.id }
    }

    /// Every row the panel shows, in order.
    private var targets: [DropTarget] {
        var all: [DropTarget] = []
        if unlistedCurrent != nil {
            all.append(.current)
        } else if let dev = connected {
            all.append(.device(dev))
        }
        return all + others.map { .device($0) }
    }

    /// Files dropped on the panel but not on a row: the only phone gets them;
    /// with several, they wait for one to be clicked.
    private func dropOnPanel(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if targets.count == 1, let only = targets.first {
            owner.send(urls, to: only)
        } else if !targets.isEmpty {
            state.pending = urls
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(state.pending.isEmpty
                     ? L("Drop files on a phone")
                     : String(format: L("Send %lld item(s) to…"), state.pending.count))
                    .font(.headline)
                Spacer()
                Button { owner.closePanel() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(L("Close"))
            }
            .padding(.bottom, 6)

            if let name = unlistedCurrent {
                header(L("Connected"))
                DropRow(name: name, online: true, pending: state.pending) { owner.send($0, to: .current) }
            } else if let dev = connected {
                header(L("Connected"))
                DropRow(name: dev.menuLabel, online: true, pending: state.pending) { owner.send($0, to: .device(dev)) }
            }
            if !others.isEmpty {
                header(L("Other phones"))
                ForEach(others) { dev in
                    DropRow(name: dev.menuLabel, online: false, pending: state.pending) { owner.send($0, to: .device(dev)) }
                }
            }
            if unlistedCurrent == nil && connected == nil && others.isEmpty {
                Text(L("No phones yet — connect one from the menu first."))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .padding(16)
        .frame(width: 300)
        // Rows take their own drops first; this catches the rest of the panel.
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadFileURLs(providers) { dropOnPanel($0) }
            return true
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }
}

/// One phone: drop files on it, or click it to send the files already held.
private struct DropRow: View {
    let name: String
    let online: Bool
    let pending: [URL]
    let send: ([URL]) -> Void

    @State private var targeted = false
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                if !online {
                    Text(L("Connects first"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Circle()
                .fill(online ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(targeted ? 0.35 : (hovered && !pending.isEmpty ? 0.15 : 0)))
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { if !pending.isEmpty { send(pending) } }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            loadFileURLs(providers, send)
            return true
        }
    }
}

private func loadFileURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { done(urls) }
}
