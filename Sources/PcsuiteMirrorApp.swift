import SwiftUI
import AppKit
import UserNotifications

@main
struct PcsuiteMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    /// First thing to run: the model below logs as it comes up, and so does the
    /// delegate, so the log has to have somewhere to go before either exists.
    init() { LogFile.captureStderrIfDiscarded() }

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
}
