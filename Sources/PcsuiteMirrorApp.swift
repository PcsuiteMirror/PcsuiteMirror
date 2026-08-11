import SwiftUI
import AppKit

@main
struct PcsuiteMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        pcsuite_log_init()
        // Tell the core which mode we're in before anything can connect — in
        // serverless mode (the default) it then refuses every cloud call.
        applyAccountToCore()
        // Menu-bar-only app: no Dock icon, no main window at launch.
        NSApp.setActivationPolicy(.accessory)
        Notifier.requestAuth()
    }
}
