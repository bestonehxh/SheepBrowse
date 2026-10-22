import AppKit

// MARK: - What the user typed

enum AddressInput {
    /// What the address field does with a line of text: a URL to load, or a Google search.
    static func url(for typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("sheep://"), let url = URL(string: lower), InternalPage(url: url) != nil { return url }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower == "about:blank" {
            if let url = URL(string: text) ?? URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") {
                return url
            }
        }
        if isHostShaped(text) {
            let scheme = prefersPlainHTTP(text) ? "http://" : "https://"
            if let url = URL(string: scheme + text) { return url }
        }
        return searchURL(for: text)
    }

    static func searchURL(for query: String) -> URL? {
        Settings.searchEngine.url(for: query)
    }

    /// "example.com", "example.com/path", "localhost:8080", "192.168.1.1", "[::1]" — no spaces, and a dot,
    /// a port, `localhost` or an IP literal in the host part.
    static func isHostShaped(_ text: String) -> Bool {
        guard !text.contains(" "), !text.hasPrefix("."), !text.hasPrefix("/") else { return false }
        let hostAndPort = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        if hostAndPort.hasPrefix("[") { return hostAndPort.contains("]") }
        let parts = hostAndPort.split(separator: ":", maxSplits: 1)
        let host = String(parts.first ?? "")
        if parts.count == 2, Int(parts[1]) == nil { return false }
        if host.lowercased() == "localhost" { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard labels.allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return false }
        // The last label must look like a TLD (letters) unless the whole thing is an IPv4 address.
        let last = labels.last!
        return last.allSatisfy(\.isLetter) || isIPv4(host)
    }

    /// Device admin pages on the LAN rarely have a trusted certificate: an IP literal, localhost or a
    /// .local name opens over http, as Chrome does for them.
    static func prefersPlainHTTP(_ text: String) -> Bool {
        let host = text.split(separator: "/").first.map { String($0.split(separator: ":").first ?? "") } ?? text
        return isIPv4(host) || host.lowercased() == "localhost" || host.lowercased().hasSuffix(".local") || text.hasPrefix("[")
    }

    static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// How a URL reads in the address field when it is not being edited (Chrome's style): no
    /// `https://`, no `www.`, no lone trailing slash.
    ///
    /// Built from the parts, never from the raw string: a user:password@ part is never shown (it was used
    /// to push the real host out of view: `https://bank.com%2Flogin%20%20…@evil.example/`), and only the
    /// path is decoded — spaces, control and bidi characters stay encoded so nothing can pad or reorder it.
    static func display(_ url: URL?) -> String {
        guard let url else { return "" }
        if url.absoluteString == "about:blank" { return "" }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = components.host, !host.isEmpty else {
            return url.absoluteString
        }
        var text = components.scheme == "https" ? "" : "\(components.scheme ?? "http")://"
        text += host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let port = components.port { text += ":\(port)" }
        var path = components.percentEncodedPath
        if let decoded = path.removingPercentEncoding,
           !decoded.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
                                                     || $0.properties.isWhitespace }) {
            path = decoded
        }
        if path == "/" && components.percentEncodedQuery == nil && components.percentEncodedFragment == nil { path = "" }
        text += path
        if let query = components.percentEncodedQuery { text += "?" + query }
        if let fragment = components.percentEncodedFragment { text += "#" + fragment }
        return text
    }

    /// localhost, .local names and private / link-local IP literals.
    static func isLocal(_ host: String?) -> Bool {
        guard let host = host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return true }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") || host == "::1" { return true }
        if host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") { return host.contains(":") }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254)
            || (parts[0] == 172 && (16...31).contains(parts[1])) || parts[0] == 0
    }

    /// "mail.google.com" → "google.com" (good enough for grouping; not a public-suffix list).
    static func site(of host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if isIPv4(host) { return host }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        let twoLevel = ["co", "com", "ac", "go", "or", "net", "org", "in", "gov"]
        let keep = twoLevel.contains(String(labels[labels.count - 2])) && labels.last!.count == 2 ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }
}

// MARK: - History

struct HistoryEntry: Codable, Hashable {
    var url: String
    var title: String
    var lastVisit: Date
    var visitCount: Int
    var typedCount: Int
}

final class HistoryStore {
    static let shared = HistoryStore()
    static let didChange = Notification.Name("SheepBrowseHistoryDidChange")

    private(set) var entries: [String: HistoryEntry] = [:]
    private var saveScheduled = false
    private let limit = 20_000

    private init() {
        for entry in AppFiles.read([HistoryEntry].self, from: "history.json") ?? [] {
            entries[entry.url] = entry
        }
    }

    func recordVisit(url: URL, title: String?, typed: Bool = false) {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        let key = url.absoluteString
        var entry = entries[key] ?? HistoryEntry(url: key, title: "", lastVisit: Date(), visitCount: 0, typedCount: 0)
        entry.visitCount += 1
        if typed { entry.typedCount += 1 }
        entry.lastVisit = Date()
        if let title, !title.isEmpty { entry.title = title }
        entries[key] = entry
        scheduleSave()
    }

    func updateTitle(url: URL, title: String) {
        guard !title.isEmpty, var entry = entries[url.absoluteString], entry.title != title else { return }
        entry.title = title
        entries[url.absoluteString] = entry
        scheduleSave()
    }

    func remove(_ urls: [String]) {
        for url in urls { entries[url] = nil }
        scheduleSave()
    }

    func clear() {
        entries.removeAll()
        scheduleSave()
    }

    /// Newest first.
    var sorted: [HistoryEntry] { entries.values.sorted { $0.lastVisit > $1.lastVisit } }

    /// Most visited sites (one per host) for the new tab page.
    func topSites(_ count: Int) -> [HistoryEntry] {
        var bestPerHost: [String: HistoryEntry] = [:]
        for entry in entries.values {
            guard let host = URL(string: entry.url)?.host else { continue }
            let score = entry.visitCount + entry.typedCount * 2
            if let current = bestPerHost[host], current.visitCount + current.typedCount * 2 >= score { continue }
            bestPerHost[host] = entry
        }
        return bestPerHost.values
            .sorted { ($0.visitCount + $0.typedCount * 2) > ($1.visitCount + $1.typedCount * 2) }
            .prefix(count).map { entry in
                // A site tile opens the site, not the deep page that happened to be visited most.
                var root = entry
                if let url = URL(string: entry.url), let scheme = url.scheme, let host = url.host {
                    root.url = "\(scheme)://\(host)/"
                }
                return root
            }
    }

    /// Address-field matches: a host that starts with the text ranks first (and can be completed
    /// inline), then title/URL contains; frecency breaks ties.
    func suggestions(for text: String, limit: Int) -> [HistoryEntry] {
        let needle = text.lowercased()
        guard !needle.isEmpty else { return [] }
        func score(_ entry: HistoryEntry) -> Double? {
            let display = AddressInput.display(URL(string: entry.url)).lowercased()
            let frecency = Double(entry.visitCount + entry.typedCount * 3)
                / (1 + Date().timeIntervalSince(entry.lastVisit) / 86_400 / 7)
            if display.hasPrefix(needle) { return 1_000 + frecency }
            if entry.title.lowercased().contains(needle) || display.contains(needle) { return frecency }
            return nil
        }
        return entries.values.compactMap { entry in score(entry).map { (entry, $0) } }
            .sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private func scheduleSave() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            saveScheduled = false
            var list = sorted
            if list.count > limit { list.removeLast(list.count - limit) }
            AppFiles.write(list, to: "history.json")
        }
    }

    func saveNow() {
        AppFiles.write(sorted, to: "history.json")
    }
}

// MARK: - Favicons

final class FaviconCache {
    static let shared = FaviconCache()
    private var memory: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private let directory: URL = {
        let dir = AppFiles.directory.appendingPathComponent("Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func file(for host: String) -> URL {
        directory.appendingPathComponent(host.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    func image(for host: String?) -> NSImage? {
        guard let host else { return nil }
        if let image = memory[host] { return image }
        if let image = NSImage(contentsOf: file(for: host)) {
            memory[host] = image
            return image
        }
        return nil
    }

    /// Tries each candidate in order; the first one that decodes is kept (memory + disk) for the host.
    /// `persist` false (a private tab): kept in memory for this run only, fetched without a disk cache.
    func fetch(host: String, candidates: [URL], persist: Bool = true, completion: @escaping (NSImage) -> Void) {
        guard !inFlight.contains(host) else { return }
        inFlight.insert(host)
        Task { @MainActor in
            defer { inFlight.remove(host) }
            let session = persist ? URLSession.shared : Self.ephemeral
            for url in candidates {
                guard let (data, response) = try? await session.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                      let image = NSImage(data: data), image.size.width > 0 else { continue }
                let icon = Self.normalized(image)
                memory[host] = icon
                if persist, let tiff = icon.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: file(for: host), options: .atomic)
                }
                completion(icon)
                return
            }
        }
    }

    private static let ephemeral = URLSession(configuration: .ephemeral)

    /// 64×64 pixels drawn at 32 pt: crisp at 16 pt on Retina, small on disk.
    private static func normalized(_ image: NSImage) -> NSImage {
        let size = NSSize(width: 32, height: 32)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: size)
        result.addRepresentation(rep)
        return result
    }

    func clear() {
        memory.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

// MARK: - Session (open windows and tabs, restored on launch)

struct SavedTab: Codable {
    var url: String?
    var title: String
    /// WebKit's `interactionState` (back/forward list and scroll position).
    var state: Data?
    var pinned: Bool?
}

struct SavedWindow: Codable {
    var frame: String
    var tabs: [SavedTab]
    var selected: Int
}

enum SessionStore {
    static func save() {
        // Private windows never reach the disk; a popup is the page's, not the user's.
        let eligible = BrowserWindowController.all.filter { !$0.isPrivate && !$0.isPopup }
        // The last window just closed: keep the session it saved (Chrome reopens it), don't write "nothing".
        guard !eligible.isEmpty || AppDelegate.shared.isTerminating else { return }
        let windows = eligible.compactMap { controller -> SavedWindow? in
            guard let window = controller.window, !controller.tabs.isEmpty else { return nil }
            return SavedWindow(frame: NSStringFromRect(window.frame),
                               tabs: controller.tabs.map(\.saved),
                               selected: controller.selectedIndex)
        }
        AppFiles.write(windows, to: "session.json")
    }

    static func load() -> [SavedWindow] {
        AppFiles.read([SavedWindow].self, from: "session.json") ?? []
    }

    private static var scheduled = false

    /// Coalesces bursts (a page load changes title, URL and favicon in quick succession).
    static func scheduleSave() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            scheduled = false
            save()
        }
    }
}

// MARK: - Recently closed (⌘⇧T)

/// Tabs and windows the user closed, newest last; kept across launches (not private ones).
struct ClosedItem: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    /// A tab …
    var tab: SavedTab?
    /// … or a whole window.
    var window: SavedWindow?

    var title: String {
        if let tab { return tab.title }
        let count = window?.tabs.count ?? 0
        return "\(count) Tabs"
    }

    var url: URL? { (tab ?? window?.tabs.first).flatMap { $0.url }.flatMap(URL.init(string:)) }
}

final class RecentlyClosed {
    static let shared = RecentlyClosed()
    private(set) var items: [ClosedItem]

    private init() {
        items = AppFiles.read([ClosedItem].self, from: "closed.json") ?? []
    }

    func add(_ item: ClosedItem) {
        items.append(item)
        if items.count > 25 { items.removeFirst(items.count - 25) }
        AppFiles.write(items, to: "closed.json")
    }

    func take(_ id: UUID? = nil) -> ClosedItem? {
        guard let index = id.map({ id in items.firstIndex { $0.id == id } }) ?? items.indices.last.map({ Optional($0) }) ?? nil else { return nil }
        let item = items.remove(at: index)
        AppFiles.write(items, to: "closed.json")
        return item
    }

    /// Opens a closed tab (in the front window) or a closed window again.
    @MainActor
    func reopen(_ id: UUID? = nil) {
        guard let item = take(id) else { return }
        if let saved = item.window {
            let controller = BrowserWindowController(frame: NSRectFromString(saved.frame))
            controller.openRestored(saved.tabs, selected: saved.selected)
            controller.showWindow(nil)
            controller.selectedTab?.wake()
        } else if let saved = item.tab {
            let target = BrowserWindowController.frontmost.flatMap { $0.isPrivate ? nil : $0 } ?? BrowserWindowController.newWindow()
            target?.reopen(saved)
        }
    }
}
