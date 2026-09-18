import Foundation
import Combine
import Sparkle

/// Thin wrapper over Sparkle 2's `SPUStandardUpdaterController`. Sparkle runs the
/// whole flow (appcast fetch, EdDSA check, download, out-of-process install,
/// relaunch) with its own UI; this only:
///
/// - keeps the controller alive for the life of the app (`shared`),
/// - mirrors `canCheckForUpdates` / `automaticallyChecksForUpdates` into
///   `@Published` so the menu and Settings follow them,
/// - does gentle reminders: a *scheduled* check that finds an update doesn't pop
///   Sparkle's window over whatever the user is doing — it sets
///   `availableVersion`, the menu shows an "Update available" row, and clicking
///   that brings Sparkle's window up. "Check for Updates…" still shows it at once.
///
/// Main thread only — Sparkle's controller assumes it.
final class UpdaterService: ObservableObject {
    static let shared = UpdaterService()

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

    /// False while a check is running (disables "Check for Updates…").
    @Published private(set) var canCheck = true
    /// Version a background check found and the user hasn't looked at yet.
    @Published private(set) var availableVersion: String?
    @Published private(set) var autoCheck = true

    private let controller: SPUStandardUpdaterController
    private let delegate = UserDriverDelegate()
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: delegate)
        let updater = controller.updater
        delegate.onUpdateFound = { [weak self] in self?.availableVersion = $0 }
        delegate.onUpdateHandled = { [weak self] in self?.availableVersion = nil }
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &cancellables)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.autoCheck = $0 }
            .store(in: &cancellables)
    }

    /// Sparkle persists this in its own defaults keys; setting it reschedules.
    func setAutoCheck(_ on: Bool) {
        controller.updater.automaticallyChecksForUpdates = on
    }

    /// User-initiated: Sparkle shows every outcome, "up to date" included. Also
    /// what the "Update available" row calls — it re-presents the found update.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Gentle-reminder half of the standard user driver.
private final class UserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var onUpdateFound: ((String) -> Void)?
    var onUpdateHandled: (() -> Void)?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Scheduled check found an update: don't let Sparkle show it; the menu does.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    /// `handleShowingUpdate == false` is exactly the case declined above.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate { onUpdateFound?(update.displayVersionString) }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        onUpdateHandled?()
    }

    func standardUserDriverWillFinishUpdateSession() {
        onUpdateHandled?()
    }
}
