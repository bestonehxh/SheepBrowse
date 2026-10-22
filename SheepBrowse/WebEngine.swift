import AppKit
import WebKit

/// Everything every tab shares: one persistent website data store (cookies survive relaunch, so a Google
/// sign-in stays signed in), Safari's user agent, and the content blocker.
final class WebEngine {
    static let shared = WebEngine()

    /// The tail WebKit appends to its user agent. WebKit's bare string names no browser; Google's sign-in
    /// treats that as an embedded web view and refuses it ("This browser or app may not be secure").
    /// Saying Safari — which this engine is — is what every WebKit browser does.
    let applicationNameForUserAgent: String = {
        let info = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        let full = (info?["CFBundleShortVersionString"] as? String) ?? "27.0"
        let majorMinor = full.split(separator: ".").prefix(2).joined(separator: ".")
        return "Version/\(majorMinor) Safari/605.1.15"
    }()

    private(set) var blockList: WKContentRuleList?
    private var compiledFor: Set<String>?

    /// One in-memory store shared by all private windows while any is open (as Safari): nothing is
    /// written to disk, and it is dropped when the last private window closes.
    private var privateStore: WKWebsiteDataStore?

    func makeConfiguration(isPrivate: Bool = false) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        if isPrivate {
            if privateStore == nil { privateStore = .nonPersistent() }
            config.websiteDataStore = privateStore!
        } else {
            config.websiteDataStore = .default()
        }
        PasswordAutofill.install(on: config.userContentController)
        config.applicationNameForUserAgent = applicationNameForUserAgent
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        config.allowsAirPlayForMediaPlayback = true
        if Settings.blockAds, let list = blockList {
            config.userContentController.add(list)
        }
        return config
    }

    /// Compiles the block list (with the sites the user allowed) and puts it on every open web view.
    func refreshBlockList() {
        let allowed = Settings.adBlockAllowedSites
        guard Settings.blockAds else {
            apply(nil)
            return
        }
        if let list = blockList, compiledFor == allowed {
            apply(list)
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "SheepBrowseBlockList", encodedContentRuleList: ContentBlocker.rulesJSON(allowing: allowed)
        ) { [weak self] list, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error { NSLog("SheepBrowse: block list did not compile: \(error)") }
                self.blockList = list
                self.compiledFor = allowed
                self.apply(Settings.blockAds ? list : nil)
            }
        }
    }

    func privateWindowsClosed() {
        if !BrowserWindowController.all.contains(where: \.isPrivate) { privateStore = nil }
    }

    private func apply(_ list: WKContentRuleList?) {
        for tab in BrowserWindowController.all.flatMap(\.tabs) {
            guard let controller = tab.webView?.configuration.userContentController else { continue }
            controller.removeAllContentRuleLists()
            if let list { controller.add(list) }
        }
    }

    func clearBrowsingData(completion: @escaping () -> Void) {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {
            MainActor.assumeIsolated {
                HistoryStore.shared.clear()
                FaviconCache.shared.clear()
                completion()
            }
        }
    }
}

/// User preferences (UserDefaults).
enum Settings {
    private static let defaults = UserDefaults.standard

    static var blockAds: Bool {
        get { defaults.object(forKey: "blockAds") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "blockAds") }
    }

    /// Hosts (registrable form, e.g. "example.com") where ads are not blocked.
    static var adBlockAllowedSites: Set<String> {
        get { Set(defaults.stringArray(forKey: "adBlockAllowedSites") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "adBlockAllowedSites") }
    }

    /// Minutes a background tab stays loaded before it sleeps; 0 = never.
    static var sleepAfterMinutes: Int {
        get { defaults.object(forKey: "sleepAfterMinutes") as? Int ?? 10 }
        set { defaults.set(newValue, forKey: "sleepAfterMinutes") }
    }

    enum SearchEngine: String, CaseIterable {
        case google, bing, duckduckgo

        var name: String {
            switch self {
            case .google: "Google"
            case .bing: "Bing"
            case .duckduckgo: "DuckDuckGo"
            }
        }

        func url(for query: String) -> URL? {
            let base: String
            switch self {
            case .google: base = "https://www.google.com/search"
            case .bing: base = "https://www.bing.com/search"
            case .duckduckgo: base = "https://duckduckgo.com/"
            }
            var components = URLComponents(string: base)!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            return components.url
        }
    }

    static var searchEngine: SearchEngine {
        get { SearchEngine(rawValue: defaults.string(forKey: "searchEngine") ?? "") ?? .google }
        set { defaults.set(newValue.rawValue, forKey: "searchEngine") }
    }

    static var searchSuggestions: Bool {
        get { defaults.object(forKey: "searchSuggestions") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "searchSuggestions") }
    }

    /// Page zoom per host (1.0 = no entry).
    static func zoom(for host: String?) -> CGFloat {
        guard let host, let value = (defaults.dictionary(forKey: "zoomBySite") ?? [:])[host] as? Double else { return 1 }
        return CGFloat(value)
    }

    static func setZoom(_ zoom: CGFloat, for host: String?) {
        guard let host else { return }
        var table = defaults.dictionary(forKey: "zoomBySite") ?? [:]
        table[host] = abs(zoom - 1) < 0.001 ? nil : Double(zoom)
        defaults.set(table, forKey: "zoomBySite")
    }
}

/// Where the app keeps its files: ~/Library/Application Support/SheepBrowse.
enum AppFiles {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SheepBrowse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Writes atomically; a failure is logged, never thrown at the UI.
    static func write<T: Encodable>(_ value: T, to name: String) {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url(name), options: .atomic)
        } catch {
            NSLog("SheepBrowse: could not write \(name): \(error)")
        }
    }

    static func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
