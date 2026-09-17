import SwiftUI
import AppKit
import UserNotifications

@main
struct PcsuiteMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    /// First thing to run: the model below logs as it comes up, and so does the
    /// delegate, so the log has to have somewhere to go before either exists.
    init() {
        LogFile.captureStderrIfDiscarded()
        SingleInstance.exitIfAlreadyRunning()
    }

    var body: some Scene {
        // Standard menu-bar dropdown (native NSMenu): the content is built from
        // Button / Toggle / Menu / Divider items. The icon reflects connection
        // state so it's readable at a glance without opening the menu.
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
    }
}

/// One running copy per bundle id.
///
/// Clicking one of our banners makes the system launch the app by bundle id, and
/// when several copies are installed (a dev build next to /Applications) it picks
/// its own — not necessarily the one running. A second instance is worse than
/// useless: its auto-reconnect over USB force-stops the phone app, which drops the
/// first instance's session, and the two then keep knocking each other off. So a
/// late arrival hands focus to the running copy and leaves before it builds the
/// model (which starts connecting).
///
/// The decision is an exclusive `flock` on a file in Application Support, not the
/// running-app list: two copies launched at the same moment (login item plus a
/// manual open) can both miss each other there, while the lock is atomic. The
/// kernel drops it when the process exits or crashes, so it never goes stale. The
/// lock path is per user and shared by every copy of the bundle, wherever it lives.
enum SingleInstance {
    /// Held open for the life of the process; closing it would release the lock.
    private static var lockFD: Int32 = -1

    static func exitIfAlreadyRunning() {
        guard !acquireLock() else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let other = Bundle.main.bundleIdentifier.flatMap { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .first(where: { $0.processIdentifier != me && !$0.isTerminated })
        }
        log("another instance is running (pid \(other.map { String($0.processIdentifier) } ?? "?"), \(other?.bundleURL?.path ?? "?")) — exiting")
        other?.activate()
        exit(0)
    }

    /// True when this process now holds the lock — or when the lock file can't be
    /// used at all: better a possible second copy than an app that won't start.
    private static func acquireLock() -> Bool {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return true }
        let dir = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "PcsuiteMirror", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("instance.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            log("single instance: can't open \(path) (errno \(errno)) — not enforcing")
            return true
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFD = fd
            return true
        }
        let err = errno
        close(fd)
        if err == EWOULDBLOCK { return false }
        log("single instance: flock failed (errno \(err)) — not enforcing")
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        pcsuite_log_init()
        // Tell the core which mode we're in before anything can connect — in
        // serverless mode (the default) it then refuses every cloud call.
        applyAccountToCore()
        // Announce this Mac on the LAN for as long as the app runs: the phone's
        // "find a computer" search discovers PCs by listening for this beacon,
        // so without it the phone reports "device not found". Needs the identity
        // in place first (the beacon carries the openID and device name).
        applyIdentityToCore()
        do { try pcsuite_presence_start() } catch { log("presence: \(ffiMessage(error))") }
        // Menu-bar-only app: no Dock icon, no main window at launch.
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        Notifier.requestAuth()
    }

    /// Show a banner even while this app is the active one. The system drops a
    /// notification from the frontmost app unless its delegate says otherwise —
    /// sensible for an app with a window the user is looking at, but this one is
    /// frontmost after any of its alerts or its Settings window, with nothing on
    /// screen for the user to see the event in. So: always present.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }

    /// A click on one of our banners. "Files received" shows that batch in
    /// Finder; the rest have nothing to open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            _ = Notifier.revealReceivedFiles(response.notification.request.content.userInfo)
        }
        done()
    }
}
