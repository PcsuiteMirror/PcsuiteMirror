import Foundation
import AppKit
import UserNotifications
import ServiceManagement

/// Log to stderr so a headless-launched binary still shows progress.
func log(_ s: String) {
    FileHandle.standardError.write(Data(("[mirror] " + s + "\n").utf8))
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

enum Notifier {
    static func requestAuth() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Notify that a user-initiated connect attempt failed (the menu dropdown may
    /// be closed, so the inline status text would go unseen).
    static func postConnectFailure(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = L("Connection failed")
        content.body = message
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// Post a local notification announcing a received SMS verify code.
    static func postCode(_ code: String) {
        let content = UNMutableNotificationContent()
        content.title = L("Verification code")
        content.body = String(format: L("%@ copied to clipboard"), code)
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// Mirror a phone notification to a native macOS banner. `title` is the
    /// notification's own title (falls back to the app name); `app` is shown as the
    /// subtitle so the source is clear.
    static func postPhoneNotification(app: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? app : title
        if !app.isEmpty && content.title != app { content.subtitle = app }
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// Announce a phone→PC「快传」batch that landed on disk.
    static func postFilesReceived(count: Int, dir: String) {
        let content = UNMutableNotificationContent()
        content.title = L("Files received")
        content.body = String(format: L("%lld file(s) saved to %@"), count, dir)
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// A phone→PC「快传」batch could not be pulled/written.
    static func postFileReceiveFailed(_ error: String) {
        let content = UNMutableNotificationContent()
        content.title = L("File transfer failed")
        content.body = error
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// A PC→phone push failed (the drop target may be closed by the time a long
    /// upload errors out, so the inline status note would go unseen).
    static func postFileSendFailed(_ error: String) {
        let content = UNMutableNotificationContent()
        content.title = L("Send failed")
        content.body = error
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
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
