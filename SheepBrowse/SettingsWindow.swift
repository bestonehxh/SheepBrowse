import AppKit
import SwiftUI

extension Settings {
    enum Startup: String, CaseIterable { case restore, newTab, page }
    enum NewTab: String, CaseIterable { case sheep, google, page }

    /// What a launch opens. (Before 1.0 (3) this was the `restoreSession` switch.)
    static var startup: Startup {
        get {
            if let raw = UserDefaults.standard.string(forKey: "startup"), let value = Startup(rawValue: raw) { return value }
            return UserDefaults.standard.object(forKey: "restoreSession") as? Bool == false ? .newTab : .restore
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "startup") }
    }

    static var startupURL: String {
        get { UserDefaults.standard.string(forKey: "startupURL") ?? "https://www.google.com/" }
        set { UserDefaults.standard.set(newValue, forKey: "startupURL") }
    }

    static var newTab: NewTab {
        get { NewTab(rawValue: UserDefaults.standard.string(forKey: "newTab") ?? "") ?? .sheep }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "newTab") }
    }

    static var newTabURL: String {
        get { UserDefaults.standard.string(forKey: "newTabURL") ?? "https://www.google.com/" }
        set { UserDefaults.standard.set(newValue, forKey: "newTabURL") }
    }

    static var homeURL: String {
        get { UserDefaults.standard.string(forKey: "homeURL") ?? "https://www.google.com/" }
        set { UserDefaults.standard.set(newValue, forKey: "homeURL") }
    }

    /// The page scrolls under the glass toolbar (macOS 26 style). Off = the page starts below it.
    static var contentUnderToolbar: Bool {
        get { UserDefaults.standard.object(forKey: "contentUnderToolbar") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "contentUnderToolbar") }
    }

    static var showHomeButton: Bool {
        get { UserDefaults.standard.object(forKey: "showHomeButton") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "showHomeButton") }
    }

    /// The page a new tab opens, nil = SheepBrowse's own new tab page.
    static var newTabPageURL: URL? {
        switch newTab {
        case .sheep: return nil
        case .google: return URL(string: "https://www.google.com/")
        case .page: return AddressInput.url(for: newTabURL)
        }
    }
}

/// macOS-style Settings: a toolbar of panes; the window takes each pane's height.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        func pane<V: View>(_ title: String, _ symbol: String, _ view: V) {
            let hosting = NSHostingController(rootView: view.frame(width: 560).fixedSize(horizontal: false, vertical: true))
            hosting.sizingOptions = [.preferredContentSize]
            hosting.title = title
            let item = NSTabViewItem(viewController: hosting)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        pane("General", "gearshape", GeneralSettings())
        pane("Privacy", "hand.raised", PrivacySettings())
        pane("Websites", "globe", SitesSettings())
        pane("Sync", "arrow.triangle.2.circlepath", SyncSettingsView())
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
}

/// A grouped section like System Settings: an optional title over a rounded box of rows.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18) { content }
            .padding(20)
    }
}

private struct GeneralSettings: View {
    @State private var startup = Settings.startup
    @State private var startupURL = Settings.startupURL
    @State private var newTab = Settings.newTab
    @State private var newTabURL = Settings.newTabURL
    @State private var homeURL = Settings.homeURL
    @State private var showHome = Settings.showHomeButton
    @State private var engine = Settings.searchEngine
    @State private var sleepAfter = Settings.sleepAfterMinutes
    @State private var suggestions = Settings.searchSuggestions
    @State private var underToolbar = Settings.contentUnderToolbar

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Start Up") {
                Picker("When SheepBrowse opens", selection: $startup) {
                    Text("Continue where you left off").tag(Settings.Startup.restore)
                    Text("Open a new tab").tag(Settings.Startup.newTab)
                    Text("Open a specific page").tag(Settings.Startup.page)
                }
                .onChange(of: startup) { Settings.startup = startup }
                if startup == .page {
                    LabeledContent("Page") {
                        TextField("", text: $startupURL, prompt: Text("https://www.google.com"))
                            .onChange(of: startupURL) { Settings.startupURL = startupURL }
                    }
                }
                Divider()
                Picker("New tabs open", selection: $newTab) {
                    Text("SheepBrowse start page").tag(Settings.NewTab.sheep)
                    Text("Google").tag(Settings.NewTab.google)
                    Text("A specific page").tag(Settings.NewTab.page)
                }
                .onChange(of: newTab) { Settings.newTab = newTab }
                if newTab == .page {
                    LabeledContent("Page") {
                        TextField("", text: $newTabURL, prompt: Text("https://"))
                            .onChange(of: newTabURL) { Settings.newTabURL = newTabURL }
                    }
                }
                Divider()
                LabeledContent("Home page") {
                    TextField("", text: $homeURL, prompt: Text("https://www.google.com"))
                        .onChange(of: homeURL) { Settings.homeURL = homeURL }
                }
                Toggle("Show Home button in the toolbar", isOn: $showHome)
                    .onChange(of: showHome) {
                        Settings.showHomeButton = showHome
                        BrowserWindowController.all.forEach { $0.refreshChrome() }
                    }
            }
            SettingsGroup(title: "Search") {
                Picker("Search engine", selection: $engine) {
                    ForEach(Settings.SearchEngine.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .onChange(of: engine) {
                    Settings.searchEngine = engine
                    BrowserWindowController.all.forEach { $0.refreshChrome() }
                }
                Toggle("Show suggestions while typing in the address bar", isOn: $suggestions)
                    .onChange(of: suggestions) { Settings.searchSuggestions = suggestions }
            }
            SettingsGroup(title: "Appearance") {
                Toggle("Pages scroll under the glass toolbar", isOn: $underToolbar)
                    .onChange(of: underToolbar) {
                        Settings.contentUnderToolbar = underToolbar
                        BrowserWindowController.all.forEach { $0.relayout() }
                    }
            }
            SettingsGroup(title: "Memory",
                          footer: "A sleeping tab frees its memory and comes back where you left it when you click it. Tabs playing audio or using the camera never sleep.") {
                Picker("Put inactive tabs to sleep after", selection: $sleepAfter) {
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("Never").tag(0)
                }
                .onChange(of: sleepAfter) { Settings.sleepAfterMinutes = sleepAfter }
            }
            SettingsGroup(title: "Updates") {
                HStack {
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { AppUpdater.shared.checkNow() }
                }
            }
            SettingsGroup(title: "Default Browser & Import") {
                HStack {
                    Button("Make SheepBrowse the Default Browser") { AppDelegate.shared.setAsDefaultBrowser(nil) }
                    Spacer()
                }
                HStack {
                    Button("Import Favorites from Chrome") { AppDelegate.shared.importChromeBookmarks(nil) }
                    Button("Import Passwords…") { AppDelegate.shared.importPasswords(nil) }
                }
            }
        }
    }
}

private struct PrivacySettings: View {
    @State private var blockAds = Settings.blockAds
    @State private var allowed = Settings.adBlockAllowedSites.sorted()

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Content Blocker",
                          footer: allowed.isEmpty ? "Blocks ad networks and trackers before they load — pages are lighter and faster."
                                                  : "Ads are shown on the sites listed above.") {
                Toggle("Block ads and trackers", isOn: $blockAds)
                    .onChange(of: blockAds) {
                        Settings.blockAds = blockAds
                        WebEngine.shared.refreshBlockList()
                        BrowserWindowController.all.forEach { $0.refreshChrome() }
                    }
                ForEach(allowed, id: \.self) { site in
                    HStack {
                        Text(site)
                        Spacer()
                        Button("Block Again") {
                            var sites = Settings.adBlockAllowedSites
                            sites.remove(site)
                            Settings.adBlockAllowedSites = sites
                            allowed = sites.sorted()
                            WebEngine.shared.refreshBlockList()
                        }
                    }
                }
            }
            SettingsGroup(title: "Browsing Data") {
                HStack {
                    Button("Clear History, Cookies and Cache…") { AppDelegate.shared.clearBrowsingData(nil) }
                    Button("Passwords…") { AppDelegate.shared.showPasswords(nil) }
                }
            }
        }
    }
}

private struct SitesSettings: View {
    @State private var certificates = CertificateTrust.all.sorted { $0.key < $1.key }
    @State private var zooms = Self.loadZooms()

    private static func loadZooms() -> [(key: String, value: Double)] {
        (UserDefaults.standard.dictionary(forKey: "zoomBySite") as? [String: Double] ?? [:]).sorted { $0.key < $1.key }
    }

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Certificates You Trusted",
                          footer: "Self-signed certificates (switches, firewalls, printers) you chose to trust. A different certificate on the same server is never accepted without asking.") {
                if certificates.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(certificates, id: \.key) { server, fingerprint in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(server)
                            Text(String(fingerprint.prefix(23)).uppercased() + "…").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") {
                            CertificateTrust.unpin(server)
                            certificates = CertificateTrust.all.sorted { $0.key < $1.key }
                        }
                    }
                }
            }
            SettingsGroup(title: "Page Zoom") {
                if zooms.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(zooms, id: \.key) { host, zoom in
                    HStack {
                        Text(host)
                        Spacer()
                        Text("\(Int(zoom * 100))%").foregroundStyle(.secondary)
                        Button("Reset") {
                            Settings.setZoom(1, for: host)
                            zooms = Self.loadZooms()
                        }
                    }
                }
            }
        }
    }
}
