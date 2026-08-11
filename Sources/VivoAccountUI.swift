import SwiftUI
import AppKit
import WebKit

// MARK: - Sign-in

/// The vendor's own login page, which is what the official desktop client embeds
/// too. It opens on the QR tab: the phone scans the code and the page completes
/// the sign-in — no password is ever typed into (or seen by) this app.
///
/// On success the page navigates to `redirectURL` and puts the credentials in a
/// single hidden input, `&`-separated, in this fixed order:
///
///     openid & vivotoken & deviceid & regioncode & checksum & cloudopenid & csrftoken
///
/// Only the first two are used here. See `docs/VIVO_ACCOUNT_LOGIN.md` §2.
enum VivoLogin {
    /// Login page. `client_id=130` is the desktop-client id.
    static let loginURL =
        "https://passport.vivo.com.cn/#/login?client_id=130&redirect_uri=" +
        "https%3A%2F%2Fpsuite.vivo.com.cn%2Fvbusiness%2Faccount%2Fcookie%2FgetHtml"

    /// Where the page lands once the account is authenticated.
    static let redirectURL = "https://psuite.vivo.com.cn/vbusiness/account/cookie/getHtml"

    /// Credentials scraped from the landing page.
    struct Result {
        var openID: String
        var token: String
    }

    /// Parse the landing page's hidden-input payload.
    static func parse(_ payload: String) -> Result? {
        let f = payload.components(separatedBy: "&")
        guard f.count >= 2 else { return nil }
        let openID = f[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let token = f[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !openID.isEmpty, !token.isEmpty else { return nil }
        return Result(openID: openID, token: token)
    }
}

/// `WKWebView` wrapper that watches for the post-login redirect and reads the
/// credentials out of the landing page.
struct VivoLoginWebView: NSViewRepresentable {
    var onResult: (VivoLogin.Result) -> Void
    var onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        // A non-persistent data store means signing out here really signs out:
        // no cookie survives to auto-log-in the next attempt.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        if let url = URL(string: VivoLogin.loginURL) {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: VivoLoginWebView
        /// The landing page is reached once; don't scrape it repeatedly.
        private var finished = false

        init(_ parent: VivoLoginWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished,
                  let url = webView.url?.absoluteString,
                  url.hasPrefix(VivoLogin.redirectURL) else { return }
            finished = true

            let js = "document.querySelector('input[type=\"hidden\"]')?.value ?? ''"
            webView.evaluateJavaScript(js) { [parent] value, _ in
                guard let payload = value as? String,
                      let result = VivoLogin.parse(payload) else {
                    parent.onFailure(L("Signed in, but the page did not return the expected credentials."))
                    return
                }
                parent.onResult(result)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onFailure(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.onFailure(error.localizedDescription)
        }
    }
}

/// Sheet-sized host for the login page.
struct VivoLoginView: View {
    var onResult: (VivoLogin.Result) -> Void
    var onCancel: () -> Void
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            VivoLoginWebView(
                onResult: { r in DispatchQueue.main.async { onResult(r) } },
                onFailure: { e in DispatchQueue.main.async { error = e } }
            )
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            Divider()
            HStack {
                Text(L("Scan the code with your phone to sign in."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("Cancel")) { onCancel() }
            }
            .padding(12)
        }
        .frame(width: 460, height: 600)
    }
}

// MARK: - Cloud model

/// One device as the connection centre knows it (parsed from the core's
/// tab-separated `pcsuite_cloud_devices()` output).
struct CloudDevice: Identifiable, Equatable {
    var id: String          // cloud deviceId
    var name: String
    var model: String
    var type: Int           // 3 = PC, otherwise a phone/pad
    /// When the device last reported itself. The API exposes no online flag, so
    /// this is all there is — shown as-is rather than guessed into a status dot.
    var reportTime: String
    var ip: String
    var externalId: String

    var isPhone: Bool { type != 3 }

    static func parse(_ line: String) -> CloudDevice? {
        let f = line.components(separatedBy: "\t")
        guard f.count >= 7, !f[0].isEmpty else { return nil }
        return CloudDevice(
            id: f[0], name: f[1], model: f[2], type: Int(f[3]) ?? 0,
            reportTime: f[4], ip: f[5], externalId: f[6]
        )
    }
}

/// Drives the account panel: sign-in state, registration, and the device roster.
/// Every FFI call here blocks on the network, so it runs on a background queue.
@MainActor
final class VivoCloudModel: ObservableObject {
    @Published var mode: ConnectionMode = Store.connectionMode
    @Published var signedIn: Bool = VivoAccount.isSignedIn
    @Published var registered: Bool = Store.vivoRegistered
    @Published var devices: [CloudDevice] = []
    @Published var busy = false
    @Published var status: String = ""
    @Published var showingLogin = false

    private let queue = DispatchQueue(label: "vivo.cloud", qos: .userInitiated)

    /// This Mac's cloud device id (derived locally; no network, no account).
    var deviceID: String { pcsuite_cloud_device_id().toString() }
    var clipPcID: String { pcsuite_cloud_clip_pc_id().toString() }

    func setMode(_ m: ConnectionMode) {
        mode = m
        Store.connectionMode = m
        applyAccountToCore()
        if m == .serverless { devices = []; status = "" }
    }

    func beginLogin() {
        status = ""
        showingLogin = true
    }

    /// Store what the login page returned, hand it to the core, and — because a
    /// signed-in account supplies both — fill in the openID and clipboard PC id
    /// that serverless mode makes the user type by hand.
    func finishLogin(_ r: VivoLogin.Result) {
        showingLogin = false
        VivoAccount.save(openID: r.openID, token: r.token)
        signedIn = true

        // The account openID *is* the LAN identity openID the phone checks.
        if Store.openID != r.openID { Store.openID = r.openID }
        // clipPcId = first 6 hex of this Mac's device id; previously it had to be
        // copied out of an existing official pairing.
        let derived = clipPcID
        if !derived.isEmpty && Store.clipPcId != derived { Store.clipPcId = derived }

        applyAccountToCore()
        status = L("Signed in.")
        register()
    }

    func signOut() {
        VivoAccount.signOut()
        signedIn = false
        registered = false
        devices = []
        status = L("Signed out.")
        applyAccountToCore()
    }

    /// Register this Mac so the phone's connection centre lists it.
    func register() {
        run(L("Registering…")) {
            let id = try pcsuite_cloud_register().toString()
            return { [weak self] in
                self?.registered = true
                Store.vivoRegistered = true
                self?.status = String(format: L("Registered as %@"), String(id.prefix(12)) + "…")
                self?.refreshDevices()
            }
        }
    }

    /// Remove this Mac from the account.
    func unregister() {
        run(L("Removing…")) {
            _ = try pcsuite_cloud_unregister().toString()
            return { [weak self] in
                self?.registered = false
                Store.vivoRegistered = false
                self?.devices = []
                self?.status = L("This Mac is no longer registered.")
            }
        }
    }

    func refreshDevices() {
        run(L("Loading devices…")) {
            let raw = try pcsuite_cloud_devices().toString()
            let list = raw.components(separatedBy: "\n").compactMap(CloudDevice.parse)
            return { [weak self] in
                self?.devices = list
                self?.status = list.isEmpty ? L("No devices on this account yet.") : ""
            }
        }
    }

    /// Run a blocking FFI call off the main thread; `work` returns a main-thread
    /// closure to apply its result.
    private func run(_ label: String, _ work: @escaping () throws -> () -> Void) {
        guard !busy else { return }
        busy = true
        status = label
        queue.async {
            do {
                let apply = try work()
                DispatchQueue.main.async { self.busy = false; apply() }
            } catch {
                let msg = ffiMessage(error)
                DispatchQueue.main.async { self.busy = false; self.status = msg }
            }
        }
    }
}

/// Push the mode + account into the core. Called at launch and whenever either
/// changes, so a cloud call can never run with stale credentials — or in
/// serverless mode, where the core refuses them outright.
func applyAccountToCore() {
    pcsuite_set_mode(Store.connectionMode.coreValue)
    if Store.connectionMode == .vivoAccount && VivoAccount.isSignedIn {
        pcsuite_cloud_set_account(VivoAccount.openID, VivoAccount.token, "cn")
    } else {
        pcsuite_cloud_set_account("", "", "")
    }
}

// MARK: - Panel

/// The mode switch plus, in account mode, sign-in / registration / device list.
struct VivoAccountView: View {
    @StateObject private var model = VivoCloudModel()
    var onConnect: (String) -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker(L("Mode"), selection: Binding(
                        get: { model.mode }, set: { model.setMode($0) }
                    )) {
                        ForEach(ConnectionMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    Text(model.mode.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(L("Connection mode"))
                }

                if model.mode == .vivoAccount {
                    Section {
                        if model.signedIn {
                            LabeledContent(L("Account")) {
                                Text(VivoAccount.openID).textSelection(.enabled)
                            }
                            LabeledContent(L("This Mac")) {
                                Text(model.registered ? L("Registered") : L("Not registered"))
                                    .foregroundStyle(model.registered ? .green : .secondary)
                            }
                            HStack {
                                Button(model.registered ? L("Re-register") : L("Register this Mac")) {
                                    model.register()
                                }
                                .disabled(model.busy)
                                if model.registered {
                                    Button(L("Remove")) { model.unregister() }
                                        .disabled(model.busy)
                                }
                                Spacer()
                                Button(L("Sign out")) { model.signOut() }
                                    .disabled(model.busy)
                            }
                        } else {
                            Button(L("Sign in by QR code…")) { model.beginLogin() }
                                .disabled(model.busy)
                            Text(L("The vivo sign-in page opens in a window; scan the code with your phone."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !model.status.isEmpty {
                            Text(model.status).font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(L("vivo account"))
                    } footer: {
                        Text(L("Registering publishes this Mac's name, model and LAN address to vivo so your phone can list it. Signing in also fills in the openID and clipboard PC id automatically."))
                    }

                    if model.signedIn {
                        Section {
                            if model.devices.isEmpty {
                                Text(L("No phones listed yet."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(model.devices.filter(\.isPhone)) { d in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(d.name.isEmpty ? d.model : d.name)
                                        Text(d.ip.isEmpty ? L("no address reported") : d.ip)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if !d.reportTime.isEmpty {
                                            Text(String(format: L("last seen %@"), d.reportTime))
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    Spacer()
                                    Button(L("Connect")) { onConnect(d.ip) }
                                        .disabled(d.ip.isEmpty)
                                }
                            }
                            Button(L("Refresh")) { model.refreshDevices() }
                                .disabled(model.busy)
                        } header: {
                            Text(L("Phones on this account"))
                        } footer: {
                            Text(L("Addresses come from the account, so a phone can be connected to without typing its IP. The phone starting the session itself is not supported yet."))
                        }
                    }

                    Section {
                        LabeledContent(L("Device id")) {
                            Text(model.deviceID.isEmpty ? "—" : model.deviceID)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    } header: {
                        Text(L("This Mac"))
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("Done")) { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 520)
        .sheet(isPresented: $model.showingLogin) {
            VivoLoginView(
                onResult: { model.finishLogin($0) },
                onCancel: { model.showingLogin = false }
            )
        }
    }
}

/// Hosts `VivoAccountView` in its own window (menu-bar apps have none by default).
final class VivoAccountWindowController {
    static let shared = VivoAccountWindowController()
    private var window: NSWindow?

    func show(onConnect: @escaping (String) -> Void) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: VivoAccountView(
            onConnect: onConnect,
            onDone: { [weak self] in self?.window?.close() }
        ))
        let w = NSWindow(contentViewController: host)
        w.title = L("Account & mode")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
