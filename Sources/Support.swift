import Foundation
import AppKit
import Network
import UserNotifications
import ServiceManagement

/// Log to stderr so a headless-launched binary still shows progress.
func log(_ s: String) {
    FileHandle.standardError.write(Data(("[mirror] " + s + "\n").utf8))
}

/// Where the log goes when nothing is reading stderr. An app opened from Finder,
/// `open`, or a login item has fd 2 on /dev/null, so everything `log()` and the
/// core's tracing write would vanish — and a phone-side event that happened an
/// hour ago is exactly what one wants to read back. So at launch, if stderr is
/// /dev/null, point it at a file. A terminal, pipe or file already there is left
/// alone (someone is reading it).
enum LogFile {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/PcsuiteMirror/app.log")
    /// Rotate once at launch when the file has grown past this (one older copy kept).
    private static let rotateAt: UInt64 = 5 << 20

    static func captureStderrIfDiscarded() {
        var cur = stat(), null = stat()
        guard fstat(2, &cur) == 0, stat("/dev/null", &null) == 0,
              cur.st_dev == null.st_dev, cur.st_ino == null.st_ino else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? UInt64, size > rotateAt {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        dup2(fd, 2)
        close(fd)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        log("──── launched \(version) pid \(getpid()) \(Date()) ────")
    }
}

/// Localized string lookup (Localizable.strings, keyed by the English source text).
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

/// Open this app at login, via the system login-item registry (`SMAppService`),
/// so the setting lives with the OS — it shows in System Settings › General ›
/// Login Items, and survives our own defaults being reset. Registers the bundle
/// at its current path, so a Debug build registers the Debug build.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// The OS can refuse (e.g. the user turned the item off in System Settings,
    /// which leaves it "requires approval"); the caller re-reads `isEnabled`.
    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Extract a human-readable message from a thrown FFI error (a `RustString`).
func ffiMessage(_ error: Error) -> String {
    if let rs = error as? RustString { return rs.toString() }
    return "\(error)"
}

/// Modal prompt for a phone IP (a standard menu can't host a text field). Returns
/// the entered string, or nil if cancelled.
func promptForIP(default value: String) -> String? {
    promptForAddress(title: L("Connect over Wi-Fi"), message: L("Enter the phone's IP address"),
                     default: value, placeholder: "192.168.x.x", button: L("Connect"))
}

/// Modal prompt for a remembered phone's Tailscale address. Returns the entered
/// string (blank = clear it), or nil if cancelled.
func promptForTailscaleIP(default value: String) -> String? {
    promptForAddress(title: L("Tailscale address"),
                     message: L("Enter the phone's Tailscale address. It is tried last, when the cable and Wi-Fi both fail. Leave blank to remove it."),
                     default: value, placeholder: "100.x.x.x", button: L("Save"))
}

private func promptForAddress(title: String, message: String, default value: String,
                              placeholder: String, button: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    field.stringValue = value
    field.placeholderString = placeholder
    alert.accessoryView = field
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: L("Cancel"))
    NSApp.activate(ignoringOtherApps: true)
    alert.window.initialFirstResponder = field
    return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
}

enum Pasteboard {
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

/// A connect failure as the menu can hand it on: the line it showed, and the
/// core's own text behind that line when the two differ.
struct ConnectFailure: Equatable {
    var shown: String
    var detail: String?

    /// What "copy" puts on the clipboard: the shown line, then the detail on its
    /// own line — unless it would only repeat the first.
    var clipboardText: String {
        guard let d = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty, d != shown else {
            return shown
        }
        return "\(shown)\n\(d)"
    }
}

/// What one SYN to a host said back.
enum ProbeVerdict {
    case open       // accepted: something is listening
    case refused    // the host answered with a reset: it is there, the port is closed
    case silent     // nothing came back in time, or there is no route to it at all
}

/// Ask every host in `hosts` whether it accepts a TCP connection on `port`: one
/// SYN each, all at once, closed the moment it is answered — nothing is ever
/// sent. A refused or unroutable host answers in milliseconds; only a silent one
/// costs the whole `timeout`. Result delivered on the main queue.
func probeTCP(_ hosts: [String], port: UInt16, timeout: TimeInterval,
              done: @escaping ([String: ProbeVerdict]) -> Void) {
    guard !hosts.isEmpty, let p = NWEndpoint.Port(rawValue: port) else { done([:]); return }
    let queue = DispatchQueue(label: "probe-tcp")
    var verdicts: [String: ProbeVerdict] = [:]
    var pending = Set(hosts)
    var conns: [NWConnection] = []
    let finish = { (host: String, verdict: ProbeVerdict) in
        guard pending.remove(host) != nil else { return }
        verdicts[host] = verdict
        if pending.isEmpty {
            conns.forEach { $0.cancel() }
            let result = verdicts
            DispatchQueue.main.async { done(result) }
        }
    }
    for host in hosts {
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        conns.append(c)
        c.stateUpdateHandler = { st in
            switch st {
            case .ready:
                finish(host, .open)
            case .failed(let err):
                if case .posix(let code) = err, code == .ECONNREFUSED {
                    finish(host, .refused)
                } else {
                    finish(host, .silent)      // no route, host unreachable, …
                }
            // `.waiting` = no path to it right now (an interface that is down);
            // it would sit there until the timeout, and the answer is already no.
            case .waiting:
                finish(host, .silent)
            default: break
            }
        }
        c.start(queue: queue)
    }
    queue.asyncAfter(deadline: .now() + timeout) {
        hosts.forEach { finish($0, .silent) }
    }
}

/// Native macOS banners. Which of the success ones actually post is the caller's
/// call (see the `notifyOn*` switches on `AppModel`); the failure ones are always
/// worth showing — the menu dropdown is usually closed when they happen, so the
/// inline status text alone would go unseen.
enum Notifier {
    /// Ask once at launch; the answer goes to the log, because "no banner
    /// appeared" has several silent causes (denied in System Settings, Focus
    /// mode, a build the system doesn't recognise) and this is the one we can
    /// rule in or out without guessing.
    static func requestAuth() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    log("notifications: authorization failed — \(error.localizedDescription)")
                } else {
                    log("notifications: \(granted ? "allowed" : "not allowed") by the user")
                }
            }
    }

    /// One fire-and-forget banner: no trigger, throwaway id, default sound.
    private static func post(title: String, subtitle: String = "", body: String,
                             userInfo: [String: Any] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        content.userInfo = userInfo
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error { log("notifications: \"\(title)\" not delivered — \(error.localizedDescription)") }
        }
    }

    /// A session came up. Names the phone and the route ("iQOO 15 · USB"); a
    /// phone we have no name for is shown as whatever the menu shows it as.
    static func postConnected(_ device: DeviceRef) {
        let transport = device.transport == .usb ? L("via USB") : L("via Wi-Fi")
        let named = !(device.name ?? "").isEmpty
        post(title: L("Connected"),
             body: named ? "\(device.displayName) · \(transport)" : device.displayName)
    }

    /// Notify that a user-initiated connect attempt failed.
    static func postConnectFailure(_ message: String) {
        post(title: L("Connection failed"), body: message)
    }

    /// Post a local notification announcing a received SMS verify code.
    static func postCode(_ code: String) {
        post(title: L("Verification code"), body: String(format: L("%@ copied to clipboard"), code))
    }

    /// Mirror a phone notification to a native macOS banner. `title` is the
    /// notification's own title (falls back to the app name); `app` is shown as the
    /// subtitle so the source is clear.
    static func postPhoneNotification(app: String, title: String, body: String) {
        let shown = title.isEmpty ? app : title
        post(title: shown, subtitle: shown == app ? "" : app, body: body)
    }

    /// A PC→phone push landed on the phone.
    static func postFilesSent(count: Int, dir: String) {
        post(title: L("Files sent"), body: String(format: L("%lld file(s) sent to %@"), count, dir))
    }

    /// Announce a phone→PC batch (快传 / 互传 / 云传输) that landed on disk.
    /// Carries the saved names and folder so a click can show them in Finder
    /// (see `revealReceivedFiles`).
    static func postFilesReceived(files: [String], dir: String) {
        post(title: L("Files received"),
             body: String(format: L("%lld file(s) saved to %@"), files.count, dir),
             userInfo: [receivedFilesKey: files, receivedDirKey: dir])
    }

    private static let receivedFilesKey = "receivedFiles"
    private static let receivedDirKey = "receivedDir"

    /// A click on a "Files received" banner: open the save folder in Finder with
    /// that batch selected. Files moved or deleted since are skipped; if none are
    /// left, the folder itself is opened. Returns false for any other banner.
    static func revealReceivedFiles(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let dir = userInfo[receivedDirKey] as? String else { return false }
        let files = userInfo[receivedFilesKey] as? [String] ?? []
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        let existing = files
            .map { folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.isEmpty {
            NSWorkspace.shared.open(folder)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
        return true
    }

    /// A phone→PC batch could not be pulled/written.
    static func postFileReceiveFailed(_ error: String) {
        post(title: L("File transfer failed"), body: error)
    }

    /// A PC→phone push failed (the drop target may be closed by the time a long
    /// upload errors out).
    static func postFileSendFailed(_ error: String) {
        post(title: L("Send failed"), body: error)
    }
}

/// NSOpenPanel for picking files to push to the phone (regular files only;
/// folders are rejected by the core's upload path anyway). Returns [] on cancel.
func pickFilesToSend() -> [URL] {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.message = L("Choose files to send to the phone")
    NSApp.activate(ignoringOtherApps: true)
    return panel.runModal() == .OK ? panel.urls : []
}
