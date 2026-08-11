import Foundation
import Security

/// How we reach the phone.
enum Transport: String, Codable {
    case usb
    case lan
}

/// A connection target the app can remember and reconnect to. For LAN we keep the
/// last IP; USB needs nothing (it's "whatever phone is on the adb cable").
struct DeviceRef: Codable, Equatable {
    var transport: Transport
    var ip: String?
    /// Phone display name when known (e.g. "iQOO 15"), used for nicer labels —
    /// populated by QR pairing. Optional → backward-compatible with stored data.
    var name: String? = nil

    /// Short label for the menu, e.g. "iQOO 15", "USB", or "192.168.1.42".
    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        switch transport {
        case .usb: return L("via USB")
        case .lan: return ip ?? L("via Wi-Fi")
        }
    }
}

/// A remembered phone, keyed by its stable unique device id (`mobileDeviceId`).
/// Device-centric: one entry per physical phone, regardless of how it's reached.
/// `lastIP` enables Wi-Fi reconnect; USB connects to whatever phone is on the cable.
struct KnownDevice: Codable, Equatable, Identifiable {
    var id: String                  // phone mobileDeviceId — stable + unique
    var name: String                // display name, e.g. "iQOO 15"
    var lastIP: String?             // last LAN IP seen (for "Connect over Wi-Fi")
    var lastTransport: Transport?   // how it was last reached

    /// Menu label: the name, falling back to the id if unnamed.
    var menuLabel: String { name.isEmpty ? id : name }

    /// Whether a (transient) connect target plausibly refers to this device —
    /// used to highlight the active device in the brief window before `/base-info`
    /// returns the real id.
    func matches(_ ref: DeviceRef) -> Bool {
        if let n = ref.name, !n.isEmpty, n == name { return true }
        if ref.transport == .lan, let ip = ref.ip, !ip.isEmpty, ip == lastIP { return true }
        return false
    }
}

/// A per-phone pairing seed (historyPhone `ext.seeds`) for the LAN connectType=2
/// path. Keyed by the phone's LAN IP. Not needed when using connectType=1.
struct SeedEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var ip: String
    var seed: String
}

/// Mirror resolution preset — caps the phone's longer screen edge (px). Lower =
/// less encode/decode latency. `.high` (0) means the core's full-resolution default.
enum MirrorResolution: String, CaseIterable, Identifiable, Codable {
    case high, medium, low
    var id: String { rawValue }
    var maxSize: Int64 {
        switch self {
        case .high: return 0      // 0 → core default (full)
        case .medium: return 1280
        case .low: return 720
        }
    }
    var label: String {
        switch self {
        case .high: return L("High (full)")
        case .medium: return L("Medium (1280)")
        case .low: return L("Low (720)")
        }
    }
}

/// Encoder bitrate cap. `.auto` omits `bit_rate` from `SCREEN_START` so the phone
/// uses its own default (~4 Mbps); the rest force an explicit override.
enum MirrorBitrate: String, CaseIterable, Identifiable, Codable {
    case auto, m4, m8, m12, m20
    var id: String { rawValue }
    var bps: Int64 {
        switch self {
        case .auto: return 0
        case .m4: return 4_000_000
        case .m8: return 8_000_000
        case .m12: return 12_000_000
        case .m20: return 20_000_000
        }
    }
    var label: String {
        switch self {
        case .auto: return L("Auto")
        case .m4: return "4 Mbps"
        case .m8: return "8 Mbps"
        case .m12: return "12 Mbps"
        case .m20: return "20 Mbps"
        }
    }
}

/// Encoder frame-rate cap. `.auto` omits `frame_rate` (phone default, 60). The
/// phone's `MediaProjection`/`VirtualDisplay` screen capture tops out at ~60fps
/// regardless of the encoder hint (`H264Encoder.DEFAULT_FRAME_RATE=60`), so 60 is
/// the ceiling; >60 isn't achievable on this path. Lower values (30) do throttle.
enum MirrorFrameRate: String, CaseIterable, Identifiable, Codable {
    case auto, fps30, fps60
    var id: String { rawValue }
    var fps: Int64 {
        switch self {
        case .auto: return 0
        case .fps30: return 30
        case .fps60: return 60
        }
    }
    var label: String {
        switch self {
        case .auto: return L("Auto")
        case .fps30: return "30"
        case .fps60: return "60"
        }
    }
}

/// One-tap encoder profiles. Each (non-`.custom`) maps to a fixed
/// resolution/bitrate/frame-rate triple; `.custom` means the current knobs don't
/// match any profile (the user fine-tuned them individually).
enum MirrorPreset: String, CaseIterable, Identifiable {
    case custom, smooth, quality, balanced, saver
    var id: String { rawValue }
    var label: String {
        switch self {
        case .custom: return L("Custom")
        case .smooth: return L("Smooth (60fps)")
        case .quality: return L("Quality (full)")
        case .balanced: return L("Balanced")
        case .saver: return L("Bandwidth saver")
        }
    }
    /// `nil` for `.custom`; otherwise the (resolution, bitrate, frame-rate) it sets.
    var triple: (MirrorResolution, MirrorBitrate, MirrorFrameRate)? {
        switch self {
        case .custom: return nil
        case .smooth: return (.medium, .m20, .fps60)   // motion-first: 60fps + headroom
        case .quality: return (.high, .m20, .fps60)    // full res, best picture
        case .balanced: return (.high, .m8, .fps60)
        case .saver: return (.low, .m4, .fps60)        // weak LAN
        }
    }
}

/// Resolved per-stream encoder settings handed to the core's `start_screen`. Bundled
/// so the mirror lifecycle (start / restart / drop-recovery) threads one value.
struct MirrorSettings: Equatable {
    var maxSize: Int64
    var bitRate: Int64
    var frameRate: Int64
    var audio: Bool
}

/// Phone facts from the `/base-info` gateway (storage capacity, model, OS) — the
/// data the desktop app shows in its device panel. Built from the tab-separated
/// string returned by `PcSession.device_info()`.
struct PhoneInfo: Equatable {
    var name: String
    var brand: String
    var product: String
    var androidVersion: String
    var osVersion: String
    var widthPixels: Int
    var heightPixels: Int
    var foldScreen: Bool
    var totalStorageGB: String
    var availableStorageGB: String
    var availableBytes: Int64
    var account: String
    /// Real vivo-account openId (16-hex) reported by the phone; "" if not logged in
    /// or an older core. Used to self-fill the pairing identity (see AppModel).
    var openID: String = ""
    /// Phone's stable unique device id (`mobileDeviceId`); "" on an older core. Keys
    /// the per-device roster (see `KnownDevice`).
    var deviceId: String = ""

    /// Parse the `device_info()` payload: tab-separated fields in a fixed order
    /// (12 legacy fields + optional 13th `openID` + optional 14th `deviceId`).
    static func parse(_ s: String) -> PhoneInfo? {
        let f = s.components(separatedBy: "\t")
        guard f.count >= 12 else { return nil }
        return PhoneInfo(
            name: f[0], brand: f[1], product: f[2], androidVersion: f[3], osVersion: f[4],
            widthPixels: Int(f[5]) ?? 0, heightPixels: Int(f[6]) ?? 0,
            foldScreen: f[7] == "1",
            totalStorageGB: f[8], availableStorageGB: f[9],
            availableBytes: Int64(f[10]) ?? 0, account: f[11],
            openID: f.count > 12 ? f[12] : "",
            deviceId: f.count > 13 ? f[13] : ""
        )
    }

    /// Compact storage summary, e.g. "327.55 / 512 GB".
    var storageSummary: String { "\(availableStorageGB) / \(totalStorageGB) GB" }
}

/// Clipboard sync direction.
enum ClipboardDirection: String, CaseIterable, Identifiable, Codable {
    case both       // two-way
    case toPhone    // Mac → phone only
    case fromPhone  // phone → Mac only
    var id: String { rawValue }
    /// Apply the phone's clipboard to this Mac (phone→PC).
    var recv: Bool { self != .toPhone }
    /// Push this Mac's clipboard to the phone (PC→phone).
    var send: Bool { self != .fromPhone }
    var label: String {
        switch self {
        case .both: return L("Two-way")
        case .toPhone: return L("Mac → phone only")
        case .fromPhone: return L("Phone → Mac only")
        }
    }
}

/// Where this Mac's identity comes from. Picked once by the user; it decides
/// whether the app is ever allowed to contact a vendor server.
enum ConnectionMode: String, CaseIterable, Identifiable, Codable {
    /// No server, ever: identity is typed in (or learned from the phone), and
    /// pairing is USB / a LAN IP / the local QR flow. The default.
    case serverless
    /// Sign in with a vivo account, which supplies the openID and registers this
    /// Mac with the vendor's connection center so the phone can list it.
    case vivoAccount

    var id: String { rawValue }

    /// The spelling the Rust core expects (`config::Mode::parse`).
    var coreValue: String { self == .vivoAccount ? "vivo_account" : "serverless" }

    var label: String {
        switch self {
        case .serverless: return L("Serverless (no account)")
        case .vivoAccount: return L("vivo account")
        }
    }

    var blurb: String {
        switch self {
        case .serverless:
            return L("Nothing leaves your network: connect over USB, a phone IP, or by scanning a QR code on this Mac.")
        case .vivoAccount:
            return L("Sign in with your vivo account to register this Mac, so it appears in the phone's connection centre.")
        }
    }
}

/// Thin UserDefaults-backed settings store. Defaults: auto-reconnect, clipboard and
/// verify-code relay are all ON out of the box (requirements 2 & 4).
enum Store {
    private static let d = UserDefaults.standard
    private static func flag(_ k: String, default def: Bool) -> Bool {
        d.object(forKey: k) as? Bool ?? def
    }

    static var autoReconnect: Bool {
        get { flag("autoReconnect", default: true) }
        set { d.set(newValue, forKey: "autoReconnect") }
    }
    static var clipboardEnabled: Bool {
        get { flag("clipboardEnabled", default: true) }
        set { d.set(newValue, forKey: "clipboardEnabled") }
    }
    static var verifyEnabled: Bool {
        get { flag("verifyEnabled", default: true) }
        set { d.set(newValue, forKey: "verifyEnabled") }
    }
    static var notifyEnabled: Bool {
        get { flag("notifyEnabled", default: true) }
        set { d.set(newValue, forKey: "notifyEnabled") }
    }
    static var showStats: Bool {
        get { flag("showStats", default: false) }
        set { d.set(newValue, forKey: "showStats") }
    }
    static var lanIP: String {
        get { d.string(forKey: "lanIP") ?? "" }
        set { d.set(newValue, forKey: "lanIP") }
    }
    static var resolution: MirrorResolution {
        get { MirrorResolution(rawValue: d.string(forKey: "resolution") ?? "") ?? .high }
        set { d.set(newValue.rawValue, forKey: "resolution") }
    }
    static var bitrate: MirrorBitrate {
        get { MirrorBitrate(rawValue: d.string(forKey: "bitrate") ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: "bitrate") }
    }
    static var frameRate: MirrorFrameRate {
        get { MirrorFrameRate(rawValue: d.string(forKey: "frameRate") ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: "frameRate") }
    }
    /// Play the phone's audio on this Mac while mirroring. On by default: it's what
    /// the official client does (the phone mutes its own speaker and the PC becomes
    /// the output), and mirroring a video with no sound reads as a bug.
    static var mirrorAudio: Bool {
        get { flag("mirrorAudio", default: true) }
        set { d.set(newValue, forKey: "mirrorAudio") }
    }
    static var clipboardDirection: ClipboardDirection {
        get { ClipboardDirection(rawValue: d.string(forKey: "clipboardDirection") ?? "") ?? .both }
        set { d.set(newValue.rawValue, forKey: "clipboardDirection") }
    }
    static var lastDevice: DeviceRef? {
        get {
            guard let data = d.data(forKey: "lastDevice") else { return nil }
            return try? JSONDecoder().decode(DeviceRef.self, from: data)
        }
        set {
            if let v = newValue, let data = try? JSONEncoder().encode(v) {
                d.set(data, forKey: "lastDevice")
            } else {
                d.removeObject(forKey: "lastDevice")
            }
        }
    }
    /// The device roster (most-recently-connected first). Populated on each
    /// successful connect once `/base-info` returns the phone's device id.
    static var knownDevices: [KnownDevice] {
        get {
            guard let data = d.data(forKey: "knownDevices") else { return [] }
            return (try? JSONDecoder().decode([KnownDevice].self, from: data)) ?? []
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "knownDevices") }
    }

    // MARK: - LAN pairing identity (only the LAN path needs these; USB ignores them)

    /// vivo account openId — the phone matches the LAN sign against this. Account-
    /// level: the same value works for every phone signed into that account.
    static var openID: String {
        get { d.string(forKey: "openID") ?? "" }
        set { d.set(newValue, forKey: "openID") }
    }
    /// Display name announced to the phone. Defaults to this Mac's name.
    static var deviceName: String {
        get { d.string(forKey: "deviceName") ?? (Host.current().localizedName ?? "My Mac") }
        set { d.set(newValue, forKey: "deviceName") }
    }
    /// PC device id / MAC (12 hex). Optional — the phone only validates openId.
    static var pcMac: String {
        get { d.string(forKey: "pcMac") ?? "" }
        set { d.set(newValue, forKey: "pcMac") }
    }
    /// Optional display account string (cosmetic, e.g. a masked phone number).
    static var accountLabel: String {
        get { d.string(forKey: "accountLabel") ?? "" }
        set { d.set(newValue, forKey: "accountLabel") }
    }
    /// Super-clipboard PC device id (6 chars). The phone pushes its clipboard only
    /// to the id it registered for this Mac at pairing, so this MUST match it for
    /// phone→Mac sync. Empty → core placeholder (phone→Mac won't work).
    static var clipPcId: String {
        get { d.string(forKey: "clipPcId") ?? "" }
        set { d.set(newValue, forKey: "clipPcId") }
    }
    /// Connect with connectType=1 (no stored seed). Recommended (and the default):
    /// it needs only the openID and works on any network. Turn off to use the per-IP
    /// `seeds` below (connectType=2) — but the connect path also auto-falls-back to
    /// connectType=1 when no seed is stored for the target IP.
    static var lanUseRemote: Bool {
        get { flag("lanUseRemote", default: true) }
        set { d.set(newValue, forKey: "lanUseRemote") }
    }
    /// Per-phone stored pairing seeds for the connectType=2 LAN path.
    static var seeds: [SeedEntry] {
        get {
            guard let data = d.data(forKey: "seeds") else { return [] }
            return (try? JSONDecoder().decode([SeedEntry].self, from: data)) ?? []
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "seeds") }
    }

    // MARK: - vivo-account mode

    /// Serverless unless the user explicitly switched — an unset or unreadable
    /// value must never opt someone into talking to a server.
    static var connectionMode: ConnectionMode {
        get { ConnectionMode(rawValue: d.string(forKey: "connectionMode") ?? "") ?? .serverless }
        set { d.set(newValue.rawValue, forKey: "connectionMode") }
    }
    /// Whether this Mac has been registered with the connection centre at least
    /// once, so the panel can say so without a network round trip.
    static var vivoRegistered: Bool {
        get { flag("vivoRegistered", default: false) }
        set { d.set(newValue, forKey: "vivoRegistered") }
    }
}

/// The signed-in vivo account. The **token is a credential**, so it lives in the
/// keychain rather than UserDefaults; the openID is not secret (the phone sees it
/// on the wire during every LAN connect) and stays with the other settings.
enum VivoAccount {
    private static let service = "tech.xvanturing.vi-conn.vivo-token"

    static var openID: String {
        get { UserDefaults.standard.string(forKey: "vivoOpenID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "vivoOpenID") }
    }

    /// Account token (`<hex>.<millis>`), read from / written to the keychain.
    static var token: String {
        get {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            SecItemDelete(base as CFDictionary)
            guard !newValue.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(newValue.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Both halves present. Says nothing about whether the token is still valid —
    /// only the server can, and it answers 401 when it isn't.
    static var isSignedIn: Bool { !openID.isEmpty && !token.isEmpty }

    /// Store the credentials the login page handed back.
    static func save(openID id: String, token t: String) {
        openID = id
        token = t
    }

    /// Forget the account (keeps the mode selection — the user may want to sign
    /// back in) and clear the registered flag.
    static func signOut() {
        openID = ""
        token = ""
        Store.vivoRegistered = false
    }
}
