import Foundation
import AppKit
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
    let alert = NSAlert()
    alert.messageText = L("Connect over Wi-Fi")
    alert.informativeText = L("Enter the phone's IP address")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    field.stringValue = value
    field.placeholderString = "192.168.x.x"
    alert.accessoryView = field
    alert.addButton(withTitle: L("Connect"))
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

/// Native macOS banners. Which of the success ones actually post is the caller's
/// call (see the `notifyOn*` switches on `AppModel`); the failure ones are always
/// worth showing — the menu dropdown is usually closed when they happen, so the
/// inline status text alone would go unseen.
enum Notifier {
    static func requestAuth() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// One fire-and-forget banner: no trigger, throwaway id, default sound.
    private static func post(title: String, subtitle: String = "", body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
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
    static func postFilesReceived(count: Int, dir: String) {
        post(title: L("Files received"), body: String(format: L("%lld file(s) saved to %@"), count, dir))
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
