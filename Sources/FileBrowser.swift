import SwiftUI
import AppKit
import CryptoKit
import UniformTypeIdentifiers

// Browse the connected phone's files: list folders and media categories, show
// thumbnails, and get files out — download to a folder, ⌘C for Finder paste, or
// drag rows straight onto Finder. Files dropped onto a folder view go up to it.
// Everything rides the session's mdfs HTTP plane (see pcsuite-core `mdfs.rs`),
// so it works alongside mirroring and clipboard sync.

/// One row of a phone listing, decoded from the core's JSON.
struct PhoneFile: Identifiable, Hashable, Decodable {
    let name: String
    let path: String
    let size: UInt64
    let isDir: Bool
    let mime: String
    /// Modification time, epoch ms (0 = unknown).
    let date: Int64
    let duration: Int64

    var id: String { path }
    var displayName: String { name.isEmpty ? (path as NSString).lastPathComponent : name }
    var ext: String { (displayName as NSString).pathExtension.lowercased() }
    var type: UTType {
        if isDir { return .folder }
        return UTType(filenameExtension: ext) ?? .data
    }
    /// Whether the phone can make a thumbnail for it (photos and videos).
    var hasThumbnail: Bool { !isDir && (type.conforms(to: .image) || type.conforms(to: .movie)) }
}

private struct PhoneListing: Decodable {
    let total: UInt64
    let entries: [PhoneFile]
}

/// A photo album from the phone's gallery.
struct PhoneAlbum: Hashable, Decodable, Identifiable {
    let keyId: String
    let name: String
    let count: UInt64
    let bucketIds: [String]
    let cover: String

    var id: String { keyId }
}

/// A place in the sidebar: a folder to browse, a media category, or an album.
enum BrowserPlace: Hashable {
    case folder(String)
    case category(String)
    case album(PhoneAlbum)

    static let storageRoot = "/"
    static let storagePrefix = "/storage/emulated/0"

    /// Where uploads land for this place; nil when it isn't a folder.
    var uploadDir: String? {
        guard case .folder(let dir) = self else { return nil }
        return dir == Self.storageRoot ? Self.storagePrefix + "/" : dir
    }
}

private struct SidebarItem: Identifiable {
    let place: BrowserPlace
    let title: String
    let symbol: String
    var id: BrowserPlace { place }
}

private let locationItems = [
    SidebarItem(place: .folder(BrowserPlace.storageRoot), title: L("Phone Storage"), symbol: "iphone"),
    SidebarItem(place: .folder(BrowserPlace.storagePrefix + "/DCIM/Camera"), title: L("Camera"), symbol: "camera"),
    SidebarItem(place: .folder(BrowserPlace.storagePrefix + "/Download"), title: L("Downloads"), symbol: "arrow.down.circle"),
]

private let categoryItems = [
    SidebarItem(place: .category("recent"), title: L("Recent"), symbol: "clock"),
    SidebarItem(place: .category("image"), title: L("Photos"), symbol: "photo"),
    SidebarItem(place: .category("video"), title: L("Videos"), symbol: "film"),
    SidebarItem(place: .category("audio"), title: L("Audio"), symbol: "waveform"),
    SidebarItem(place: .category("doc"), title: L("Documents"), symbol: "doc.text"),
]

// MARK: - Model

final class FileBrowserModel: ObservableObject {
    let app: AppModel

    @Published private(set) var place: BrowserPlace = .folder(BrowserPlace.storageRoot)
    @Published private(set) var files: [PhoneFile] = []
    @Published private(set) var albums: [PhoneAlbum] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var transfers: [FileTransfer] = []
    @Published var uploading = 0

    private var backStack: [BrowserPlace] = []
    private var forwardStack: [BrowserPlace] = []
    private var loadGen = 0
    private var pollTimer: Timer?

    let thumbnails: ThumbnailStore

    init(app: AppModel) {
        self.app = app
        self.thumbnails = ThumbnailStore(session: { [weak app] in app?.fileSession() })
        purgeOldTransfers()
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func go(_ to: BrowserPlace) {
        guard to != place else { return }
        backStack.append(place)
        forwardStack.removeAll()
        place = to
        reload()
    }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        forwardStack.append(place)
        place = prev
        reload()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(place)
        place = next
        reload()
    }

    func open(_ file: PhoneFile) {
        if file.isDir { go(.folder(file.path)) } else { download([file]) }
    }

    /// Fetch the current place again, every page of it. A newer reload makes an
    /// older one's result land nowhere.
    func reload() {
        loadGen += 1
        let gen = loadGen
        let place = self.place
        guard let session = app.fileSession() else {
            files = []
            error = nil
            loading = false
            return
        }
        loading = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Self.fetch(place, session: session) }
            DispatchQueue.main.async {
                guard let self, self.loadGen == gen else { return }
                self.loading = false
                switch result {
                case .success(let rows): self.files = rows
                case .failure(let e):
                    self.files = []
                    self.error = e.localizedDescription
                }
            }
        }
    }

    /// Refresh the album list in the sidebar.
    func reloadAlbums() {
        guard let session = app.fileSession() else {
            albums = []
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let json = try session.list_albums().toString()
                let list = try JSONDecoder().decode([PhoneAlbum].self, from: Data(json.utf8))
                DispatchQueue.main.async { self?.albums = list }
            } catch {
                log("file browser: albums: \(ffiMessage(error))")
            }
        }
    }

    private static let pageSize: UInt32 = 500

    private static func fetch(_ place: BrowserPlace, session: PcSession) throws -> [PhoneFile] {
        switch place {
        case .category(let kind):
            return try decode(session.list_category(RustString(kind)).toString()).entries
        case .album(let album):
            let ids = RustVec<RustString>()
            album.bucketIds.forEach { ids.push(value: RustString($0)) }
            return try decode(session.list_album(RustString(album.keyId), ids).toString()).entries
        case .folder(let dir):
            var rows: [PhoneFile] = []
            var page: UInt32 = 0
            while true {
                let listing = try decode(session.list_dir(RustString(dir), page, pageSize).toString())
                rows += listing.entries
                page += 1
                if listing.entries.isEmpty || UInt64(rows.count) >= listing.total { break }
            }
            return rows
        }
    }

    private static func decode(_ json: String) throws -> PhoneListing {
        try JSONDecoder().decode(PhoneListing.self, from: Data(json.utf8))
    }

    // MARK: Breadcrumbs

    /// `(title, place)` from the storage root down to the current folder.
    var breadcrumbs: [(String, BrowserPlace)] {
        switch place {
        case .category(let kind):
            let title = categoryItems.first { $0.place == .category(kind) }?.title ?? kind
            return [(title, place)]
        case .album(let album):
            return [(album.name, place)]
        case .folder(let dir):
            var crumbs: [(String, BrowserPlace)] = [(L("Phone Storage"), .folder(BrowserPlace.storageRoot))]
            guard dir != BrowserPlace.storageRoot else { return crumbs }
            var base = ""
            var rest = dir
            if dir.hasPrefix(BrowserPlace.storagePrefix + "/") {
                base = BrowserPlace.storagePrefix
                rest = String(dir.dropFirst(base.count))
            }
            for part in rest.split(separator: "/") {
                base += "/" + part
                crumbs.append((String(part), .folder(base)))
            }
            return crumbs
        }
    }

    // MARK: Downloads

    /// Ask where, then download there and show the result in Finder.
    func download(_ files: [PhoneFile]) {
        guard !files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Download")
        panel.message = String(format: L("Download %lld item(s) from the phone to:"), files.count)
        panel.directoryURL = Self.lastDownloadDir
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Self.lastDownloadDir = dir
        start(files, into: dir, purpose: .save)
    }

    /// Download into a scratch folder, then put the files on the pasteboard so a
    /// Finder ⌘V pastes them.
    func copyToPasteboard(_ files: [PhoneFile]) {
        guard !files.isEmpty else { return }
        start(files, into: Self.newScratchDir(), purpose: .pasteboard)
    }

    /// A drag source for one row: Finder asks for the file when it's dropped,
    /// and gets it once the download finishes.
    func dragProvider(_ file: PhoneFile) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = file.displayName
        provider.registerFileRepresentation(forTypeIdentifier: file.type.identifier,
                                            fileOptions: [],
                                            visibility: .all) { [weak self] completion in
            let progress = Progress(totalUnitCount: Int64(max(file.size, 1)))
            DispatchQueue.main.async {
                guard let self else {
                    completion(nil, false, FileBrowserError(L("The file browser was closed.")))
                    return
                }
                self.start([file], into: Self.newScratchDir(), purpose: .drag(progress, { url, err in
                    completion(url, false, err)
                }))
            }
            return progress
        }
        return provider
    }

    private func start(_ files: [PhoneFile], into dir: URL, purpose: FileTransfer.Purpose) {
        guard let session = app.fileSession() else {
            purpose.fail(FileBrowserError(L("Phone not connected.")))
            return
        }
        let items: [[String: Any]] = files.map { ["path": $0.path, "isDir": $0.isDir, "size": $0.size] }
        let json = (try? JSONSerialization.data(withJSONObject: items)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let title = files.count == 1 ? files[0].displayName : String(format: L("%lld items"), files.count)
        let transfer = FileTransfer(title: title, total: 0, purpose: purpose)
        transfers.append(transfer)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Folders list as size 0; ask the phone so the progress bar has an end.
            // A folder it can't size leaves the total unknown (a spinner).
            var total: UInt64 = 0
            var known = true
            for f in files {
                if f.isDir {
                    let size = session.directory_size(RustString(f.path))
                    if size == 0 { known = false }
                    total += size
                } else {
                    total += f.size
                }
            }
            // Resolving the phone's device id can take a moment on a fresh session.
            let handle = session.start_download(RustString(json), RustString(dir.path))
            DispatchQueue.main.async {
                transfer.total = known ? total : 0
                transfer.progress?.totalUnitCount = Int64(max(total, 1))
                transfer.handle = handle
                self?.startPolling()
            }
        }
    }

    // MARK: Changes on the phone

    /// Run one phone-side change off the main thread, then refresh. A failure
    /// shows in the path bar.
    private func change(_ what: String, _ body: @escaping (PcSession) throws -> Void) {
        guard let session = app.fileSession() else {
            error = L("Phone not connected.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            do { try body(session) } catch { failure = ffiMessage(error) }
            DispatchQueue.main.async {
                guard let self else { return }
                if let failure {
                    log("file browser: \(what) failed: \(failure)")
                    self.error = failure.contains("already exists")
                        ? L("An item with that name already exists.")
                        : String(format: L("%@ failed: %@"), what, failure)
                }
                self.reload()
            }
        }
    }

    func createFolder(named name: String) {
        guard let parent = place.uploadDir, let name = Self.validName(name) else { return }
        change(L("New Folder")) { _ = try $0.create_directory(RustString(parent), RustString(name)) }
    }

    func rename(_ file: PhoneFile, to newName: String) {
        guard let name = Self.validName(newName), name != file.displayName else { return }
        change(L("Rename")) { _ = try $0.rename_path(RustString(file.path), RustString(name)) }
    }

    func delete(_ files: [PhoneFile]) {
        guard !files.isEmpty else { return }
        change(L("Delete")) { session in
            let paths = RustVec<RustString>()
            files.forEach { paths.push(value: RustString($0.path)) }
            let json = try session.delete_paths(paths).toString()
            let result = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            let deleted = (result?["deleted"] as? NSNumber)?.intValue ?? files.count
            if deleted < files.count {
                throw FileBrowserError(String(format: L("%lld of %lld items could not be deleted."),
                                              files.count - deleted, files.count))
            }
        }
    }

    /// A trimmed name with no path separator, or nil when it can't be a name.
    private static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        return name
    }

    /// Whether files here are real folder contents that can be renamed or
    /// created — categories and albums are views across folders.
    var isFolderView: Bool { place.uploadDir != nil }

    func cancel(_ transfer: FileTransfer) {
        transfer.handle?.cancel()
    }

    func dismiss(_ transfer: FileTransfer) {
        transfers.removeAll { $0 === transfer }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        var running = false
        for t in transfers where t.state == .running {
            guard let handle = t.handle else { running = true; continue }
            guard let status = try? JSONSerialization.jsonObject(with: Data(handle.status().toString().utf8)) as? [String: Any] else {
                continue
            }
            t.bytes = (status["bytes"] as? NSNumber)?.uint64Value ?? t.bytes
            t.progress?.completedUnitCount = Int64(t.bytes)
            switch status["state"] as? String {
            case "done":
                let paths = (status["paths"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
                finish(t, paths: paths)
            case "failed":
                t.state = .failed
                t.error = status["error"] as? String ?? ""
                t.purpose.fail(FileBrowserError(t.error))
                log("file browser: download failed: \(t.error)")
            case "cancelled":
                t.state = .cancelled
                t.purpose.fail(FileBrowserError(L("Cancelled")))
                transfers.removeAll { $0 === t }
            default:
                running = true
            }
        }
        objectWillChange.send()
        if !running {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func finish(_ t: FileTransfer, paths: [URL]) {
        t.state = .done
        switch t.purpose {
        case .save:
            NSWorkspace.shared.activateFileViewerSelecting(paths)
        case .pasteboard:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(paths as [NSURL])
        case .drag(_, let completion):
            completion(paths.first, nil)
        }
        // A finished row lingers briefly so the user sees it land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.transfers.removeAll { $0 === t }
        }
    }

    // MARK: Uploads

    func upload(_ urls: [URL]) {
        guard let dir = place.uploadDir, !urls.isEmpty else { return }
        uploading += 1
        app.pushFiles(urls, phoneDir: dir)
    }

    func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("Upload")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        upload(panel.urls)
    }

    /// A push finished: refresh if we were waiting on one.
    func pushFinished() {
        guard uploading > 0 else { return }
        uploading -= 1
        reload()
    }

    // MARK: Scratch space

    private static let lastDownloadDirKey = "fileBrowser.downloadDir"

    private static var lastDownloadDir: URL {
        get {
            if let p = UserDefaults.standard.string(forKey: lastDownloadDirKey) { return URL(fileURLWithPath: p) }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        set { UserDefaults.standard.set(newValue.path, forKey: lastDownloadDirKey) }
    }

    /// Where copies and drags download to before the pasteboard/Finder takes them.
    private static var scratchRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "PcsuiteMirror")
            .appendingPathComponent("PhoneFiles", isDirectory: true)
    }

    private static func newScratchDir() -> URL {
        scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Scratch downloads older than a day have long been pasted or dropped.
    private func purgeOldTransfers() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-86_400)
        guard let dirs = try? fm.contentsOfDirectory(at: Self.scratchRoot, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for d in dirs {
            let created = (try? d.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: d) }
        }
    }
}

struct FileBrowserError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One download, as the status bar shows it.
final class FileTransfer: Identifiable {
    enum State { case running, done, failed, cancelled }
    enum Purpose {
        /// Downloaded into a folder the user picked; reveal when done.
        case save
        /// For ⌘C: put the files on the pasteboard when done.
        case pasteboard
        /// For a drag onto Finder: report back to the drop.
        case drag(Progress, (URL?, Error?) -> Void)

        var progress: Progress? {
            if case .drag(let p, _) = self { return p }
            return nil
        }

        func fail(_ error: Error) {
            if case .drag(_, let completion) = self { completion(nil, error) }
        }
    }

    let title: String
    /// Summed size, or 0 while unknown.
    var total: UInt64
    let purpose: Purpose
    var handle: PcDownload?
    var bytes: UInt64 = 0
    var state = State.running
    var error = ""

    var progress: Progress? { purpose.progress }

    init(title: String, total: UInt64, purpose: Purpose) {
        self.title = title
        self.total = total
        self.purpose = purpose
    }
}

// MARK: - Thumbnails

/// Phone thumbnails, cached on disk by path + size + date so a changed file gets
/// a fresh one. Requests from rows scrolling into view are batched into one call.
final class ThumbnailStore: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]

    private let session: () -> PcSession?
    private var pending: [PhoneFile] = []
    private var requested: Set<String> = []
    private var flushScheduled = false
    private let queue = DispatchQueue(label: "com.pcsuite.thumbnails")
    private static let batchSize = 40

    private static var cacheDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "PcsuiteMirror")
            .appendingPathComponent("PhoneThumbnails", isDirectory: true)
    }

    init(session: @escaping () -> PcSession?) {
        self.session = session
    }

    /// Main thread. Loads from disk, or queues a fetch.
    func request(_ file: PhoneFile) {
        guard file.hasThumbnail, !requested.contains(file.path) else { return }
        requested.insert(file.path)
        pending.append(file)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        let batch = pending
        pending.removeAll()
        // Taken here, on main, where the app's connection state lives.
        let s = session()
        queue.async { [weak self] in self?.load(batch, session: s) }
    }

    private static func key(_ f: PhoneFile) -> String {
        let digest = SHA256.hash(data: Data("\(f.path)|\(f.size)|\(f.date)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func load(_ batch: [PhoneFile], session: PcSession?) {
        let fm = FileManager.default
        var found: [String: NSImage] = [:]
        var missing: [PhoneFile] = []
        for f in batch {
            let file = Self.cacheDir.appendingPathComponent(Self.key(f) + ".jpg")
            if let img = NSImage(contentsOf: file) {
                found[f.path] = img
            } else if !fm.fileExists(atPath: file.appendingPathExtension("none").path) {
                missing.append(f)
            }
        }
        publish(found)
        guard !missing.isEmpty, let s = session else {
            // Not connected: forget these so they're asked for after a reconnect.
            DispatchQueue.main.async { [weak self] in
                missing.forEach { self?.requested.remove($0.path) }
            }
            return
        }
        try? fm.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
        for start in stride(from: 0, to: missing.count, by: Self.batchSize) {
            let chunk = Array(missing[start..<min(start + Self.batchSize, missing.count)])
            let paths = RustVec<RustString>()
            let outs = RustVec<RustString>()
            let files = chunk.map { Self.cacheDir.appendingPathComponent(Self.key($0) + ".jpg") }
            for (f, out) in zip(chunk, files) {
                paths.push(value: RustString(f.path))
                outs.push(value: RustString(out.path))
            }
            do {
                _ = try s.fetch_thumbnails(paths, outs)
            } catch {
                log("thumbnails: \(ffiMessage(error))")
                // Let these be asked for again next time the rows show.
                DispatchQueue.main.async { [weak self] in
                    chunk.forEach { self?.requested.remove($0.path) }
                }
                continue
            }
            var got: [String: NSImage] = [:]
            for (f, out) in zip(chunk, files) {
                if let img = NSImage(contentsOf: out) {
                    got[f.path] = img
                } else {
                    // The phone has none for it (e.g. an unsupported format); don't ask again.
                    fm.createFile(atPath: out.appendingPathExtension("none").path, contents: nil)
                }
            }
            publish(got)
        }
    }

    private func publish(_ imgs: [String: NSImage]) {
        guard !imgs.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.images.merge(imgs) { _, new in new }
        }
    }
}

// MARK: - Views

struct FileBrowserView: View {
    @ObservedObject var app: AppModel
    @StateObject private var model: FileBrowserModel
    @State private var selection = Set<PhoneFile.ID>()
    @State private var sortOrder = [KeyPathComparator(\PhoneFile.displayName, comparator: .localizedStandard)]
    @State private var filter = ""
    @State private var dropTargeted = false
    // The name prompt: shown for a new folder (renaming == nil) or a rename.
    @State private var namePromptShown = false
    @State private var renaming: PhoneFile?
    @State private var nameText = ""
    @State private var pendingDelete: [PhoneFile] = []
    @State private var deleteConfirmShown = false
    // Sidebar groups the user folded away stay folded across launches, as in Finder.
    @AppStorage("fileBrowser.sidebar.locations") private var locationsExpanded = true
    @AppStorage("fileBrowser.sidebar.categories") private var categoriesExpanded = true
    @AppStorage("fileBrowser.sidebar.albums") private var albumsExpanded = true

    init(app: AppModel) {
        self.app = app
        _model = StateObject(wrappedValue: FileBrowserModel(app: app))
    }

    private var shown: [PhoneFile] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        let rows = q.isEmpty ? model.files : model.files.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
        let sorted = rows.sorted(using: sortOrder)
        // Folders stay on top, whatever the column sort.
        return sorted.filter(\.isDir) + sorted.filter { !$0.isDir }
    }

    private var selectedFiles: [PhoneFile] {
        model.files.filter { selection.contains($0.id) }
    }

    static let windowID = "phone-files"

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
        } detail: {
            VStack(spacing: 0) {
                content
                Divider()
                pathBar
            }
            .navigationTitle(model.breadcrumbs.last?.0 ?? L("Phone Files"))
            .navigationSubtitle(app.isConnected ? summary : "")
            .toolbar { toolbar }
            .searchable(text: $filter, placement: .toolbar, prompt: L("Filter"))
        }
        .frame(minWidth: 720, minHeight: 420)
        .onAppear {
            model.reload()
            model.reloadAlbums()
        }
        .onChange(of: app.isConnected) { _ in
            selection.removeAll()
            model.reload()
            model.reloadAlbums()
        }
        .onChange(of: app.pushGeneration) { _ in model.pushFinished() }
        .alert(renaming == nil ? L("New Folder") : L("Rename"), isPresented: $namePromptShown) {
            TextField(L("Name"), text: $nameText)
            Button(renaming == nil ? L("Create") : L("Rename")) {
                if let file = renaming { model.rename(file, to: nameText) } else { model.createFolder(named: nameText) }
            }
            .keyboardShortcut(.defaultAction)
            Button(L("Cancel"), role: .cancel) {}
        }
        .alert(deleteTitle, isPresented: $deleteConfirmShown) {
            Button(L("Delete"), role: .destructive) { model.delete(pendingDelete) }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("This deletes them on the phone. It can't be undone here."))
        }
    }

    private var deleteTitle: String {
        pendingDelete.count == 1
            ? String(format: L("Delete “%@”?"), pendingDelete[0].displayName)
            : String(format: L("Delete %lld items?"), pendingDelete.count)
    }

    private func promptNewFolder() {
        renaming = nil
        nameText = L("untitled folder")
        namePromptShown = true
    }

    private func promptRename(_ file: PhoneFile) {
        renaming = file
        nameText = file.displayName
        namePromptShown = true
    }

    private func confirmDelete(_ files: [PhoneFile]) {
        guard !files.isEmpty else { return }
        pendingDelete = files
        deleteConfirmShown = true
    }

    private var sidebar: some View {
        List(selection: Binding(get: { model.place }, set: { if let p = $0 { model.go(p) } })) {
            // The phone's own name heads its locations, as a mounted volume would.
            SidebarSection(title: app.lastDevice?.displayName ?? L("Locations"), expanded: $locationsExpanded) {
                ForEach(locationItems) { item in
                    Label(item.title, systemImage: item.symbol).tag(item.place)
                }
            }
            SidebarSection(title: L("Categories"), expanded: $categoriesExpanded) {
                ForEach(categoryItems) { item in
                    Label(item.title, systemImage: item.symbol).tag(item.place)
                }
            }
            if !model.albums.isEmpty {
                SidebarSection(title: L("Albums"), expanded: $albumsExpanded) {
                    ForEach(model.albums) { album in
                        Label(album.name, systemImage: "photo.on.rectangle")
                            .badge(Int(album.count))
                            .tag(BrowserPlace.album(album))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label(L("Back"), systemImage: "chevron.left") }
                .disabled(!model.canGoBack)
                .help(L("Back"))
                .keyboardShortcut("[")
            Button { model.goForward() } label: { Label(L("Forward"), systemImage: "chevron.right") }
                .disabled(!model.canGoForward)
                .help(L("Forward"))
                .keyboardShortcut("]")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.reload() } label: { Label(L("Refresh"), systemImage: "arrow.clockwise") }
                .help(L("Refresh"))
                .keyboardShortcut("r")
                .disabled(!app.isConnected)
            Button { promptNewFolder() } label: { Label(L("New Folder"), systemImage: "folder.badge.plus") }
                .help(L("New Folder"))
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.isFolderView || !app.isConnected)
            Button { confirmDelete(selectedFiles) } label: { Label(L("Delete"), systemImage: "trash") }
                .help(L("Delete"))
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selection.isEmpty)
            Button { model.pickAndUpload() } label: { Label(L("Upload"), systemImage: "square.and.arrow.up") }
                .help(L("Upload to this folder…"))
                .disabled(model.place.uploadDir == nil || !app.isConnected)
            Button { model.copyToPasteboard(selectedFiles) } label: { Label(L("Copy (paste in Finder)"), systemImage: "doc.on.doc") }
                .help(L("Copy (paste in Finder)"))
                .keyboardShortcut("c")
                .disabled(selection.isEmpty)
            Button { model.download(selectedFiles) } label: { Label(L("Download…"), systemImage: "arrow.down.circle") }
                .help(L("Download…"))
                .keyboardShortcut("s")
                .disabled(selection.isEmpty)
        }
    }

    /// Finder-style path bar along the bottom, with the transfers on its right.
    private var pathBar: some View {
        let crumbs = model.breadcrumbs
        return HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { i, crumb in
                        if i > 0 {
                            Image(systemName: "chevron.right")
                                .imageScale(.small)
                                .foregroundStyle(.tertiary)
                        }
                        Button { model.go(crumb.1) } label: {
                            Label(crumb.0, systemImage: i == 0 ? "iphone" : "folder")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(i == crumbs.count - 1 ? .primary : .secondary)
                    }
                }
            }
            if model.uploading > 0 {
                ProgressView().controlSize(.small)
                Text(L("Uploading…")).foregroundStyle(.secondary)
            }
            if let error = model.error, !model.files.isEmpty {
                Text(error).foregroundStyle(.red).lineLimit(1).help(error)
            }
            ForEach(model.transfers.suffix(3)) { t in
                TransferView(transfer: t, cancel: { model.cancel(t) }, dismiss: { model.dismiss(t) })
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.bar)
    }

    @ViewBuilder private var content: some View {
        if !app.isConnected {
            placeholder(L("Phone not connected"), detail: L("Connect a phone from the menu bar to browse its files."))
        } else if let error = model.error, model.files.isEmpty {
            placeholder(L("Couldn't load this folder"), detail: error)
        } else {
            table
                .overlay {
                    if model.loading && model.files.isEmpty {
                        ProgressView()
                    } else if !model.loading && model.files.isEmpty {
                        Text(L("Empty")).foregroundStyle(.secondary)
                    }
                }
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor, lineWidth: 3)
                            .padding(2)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    guard model.place.uploadDir != nil else { return false }
                    loadURLs(providers) { model.upload($0) }
                    return true
                }
        }
    }

    private var table: some View {
        Table(of: PhoneFile.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(L("Name"), value: \.displayName, comparator: .localizedStandard) { file in
                FileNameCell(file: file, thumbnails: model.thumbnails)
            }
            TableColumn(L("Size"), value: \.size) { file in
                Text(file.isDir ? "—" : ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90, max: 120)
            TableColumn(L("Date Modified"), value: \.date) { file in
                Text(file.date > 0 ? Self.dateFormatter.string(from: Date(timeIntervalSince1970: Double(file.date) / 1000)) : "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150, max: 200)
        } rows: {
            ForEach(shown) { file in
                TableRow(file)
                    .itemProvider { model.dragProvider(file) }
            }
        }
        .contextMenu(forSelectionType: PhoneFile.ID.self) { ids in
            let files = model.files.filter { ids.contains($0.id) }
            if files.count == 1, files[0].isDir {
                Button(L("Open")) { model.open(files[0]) }
            }
            Button(L("Download…")) { model.download(files) }
                .disabled(files.isEmpty)
            Button(L("Copy (paste in Finder)")) { model.copyToPasteboard(files) }
                .disabled(files.isEmpty)
            Divider()
            if files.count == 1 {
                Button(L("Rename…")) { promptRename(files[0]) }
            }
            if model.isFolderView {
                Button(L("New Folder…")) { promptNewFolder() }
            }
            if !files.isEmpty {
                Divider()
                Button(L("Delete…"), role: .destructive) { confirmDelete(files) }
            }
        } primaryAction: { ids in
            let files = model.files.filter { ids.contains($0.id) }
            if files.count == 1 { model.open(files[0]) } else { model.download(files) }
        }
        .onChange(of: model.place) { _ in selection.removeAll() }
    }

    private var summary: String {
        if !selection.isEmpty {
            return String(format: L("%lld of %lld selected"), selection.count, model.files.count)
        }
        return String(format: L("%lld items"), model.files.count)
    }

    private func placeholder(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
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

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

/// A sidebar group that folds like Finder's (chevron on hover, macOS 14+).
/// macOS 13 has no collapsible `Section`, so there it simply stays open.
private struct SidebarSection<Content: View>: View {
    let title: String
    @Binding var expanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 14.0, *) {
            Section(isExpanded: $expanded) { content } header: { Text(title) }
        } else {
            Section { content } header: { Text(title) }
        }
    }
}

private struct FileNameCell: View {
    let file: PhoneFile
    @ObservedObject var thumbnails: ThumbnailStore

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let img = thumbnails.images[file.path] {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(for: file.type))
                        .resizable()
                        .frame(width: 24, height: 24)
                }
            }
            .frame(width: 24, height: 24)
            Text(file.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(file.path)
        .onAppear { thumbnails.request(file) }
    }
}

private struct TransferView: View {
    let transfer: FileTransfer
    let cancel: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            switch transfer.state {
            case .running:
                if transfer.total > 0 {
                    ProgressView(value: Double(transfer.bytes), total: Double(transfer.total))
                        .frame(width: 80)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("\(transfer.title) · \(ByteCountFormatter.string(fromByteCount: Int64(transfer.bytes), countStyle: .file))")
                    .lineLimit(1)
                Button { cancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help(L("Cancel"))
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(transfer.title).lineLimit(1)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(transfer.title).lineLimit(1).help(transfer.error)
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            case .cancelled:
                EmptyView()
            }
        }
        .frame(maxWidth: 260, alignment: .trailing)
    }
}
