import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let shared = AppDelegate()
    private var sleepTimer: Timer?
    private var audioTimer: Timer?
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var launchURLs: [URL] = []
    private var launched = false
    /// Windows closing because the app quits are not "recently closed".
    private(set) var isTerminating = false

    static func main() {
        let app = NSApplication.shared
        app.delegate = AppDelegate.shared
        app.setActivationPolicy(.regular)
        app.run()
    }

    // MARK: Launch and quit

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        UserDefaults.standard.register(defaults: ["NSWindowRestoresWorkspaceAtLaunch": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        WebEngine.shared.refreshBlockList()
        switch Settings.startup {
        case .restore:
            for saved in SessionStore.load() where !saved.tabs.isEmpty {
                let controller = BrowserWindowController(frame: NSRectFromString(saved.frame))
                controller.openRestored(saved.tabs, selected: saved.selected)
                controller.showWindow(nil)
            }
        case .page:
            if launchURLs.isEmpty, let url = AddressInput.url(for: Settings.startupURL) {
                let tab = BrowserTab()
                tab.load(url)
                BrowserWindowController.newWindow(with: tab)
            }
        case .newTab:
            break
        }
        if BrowserWindowController.all.isEmpty && launchURLs.isEmpty { BrowserWindowController.newWindow() }
        launched = true
        open(launchURLs)
        launchURLs = []

        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { AppDelegate.shared.sleepIdleTabs() }
        }
        audioTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                for tab in BrowserWindowController.all.flatMap(\.tabs) where !tab.isAsleep { tab.pollAudio() }
            }
        }
        // When macOS runs low on memory, every background tab sleeps at once.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { BrowserWindowController.all.forEach { $0.sleepIdleTabs(olderThan: 0) } }
        }
        source.resume()
        memoryPressure = source
        SyncController.shared.start()
        GoogleAccount.shared.start()
        AppUpdater.start()
        WebNotificationBridge.shared.start()
        CaptureIsland.shared.start()
        #if DEBUG
        // Screenshots: SHEEPBROWSE_DEBUG_OPEN=tabsearch|downloads|favorites|history|passwords opens that at launch.
        if let what = ProcessInfo.processInfo.environment["SHEEPBROWSE_DEBUG_OPEN"], let front = BrowserWindowController.frontmost {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                switch what {
                case "tabsearch": front.searchTabs(nil)
                case "swipe": SwipeTest.run(in: front)
                case "passwords": PasswordsWindowController.shared.showWindow(nil)
                case "settings": SettingsWindowController.shared.showWindow(nil)
                case "island":
                    front.open(URL(string: "https://example.com/")!, typed: true, disposition: .current)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { front.selectedTab?.debugFakeCapture() }
                case "islandopen":
                    front.open(URL(string: "https://example.com/")!, typed: true, disposition: .current)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        front.selectedTab?.debugFakeCapture()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { CaptureIsland.shared.debugExpand() }
                    }
                case "render":
                    // Writes PNGs of the account card (closed / choosing) and the window's header to /tmp/claude-501/render.
                    let dir = URL(fileURLWithPath: "/tmp/claude-501/render")
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    for choosing in [false, true] {
                        let renderer = ImageRenderer(content: AccountCard(startEditing: choosing)
                            .background(Color(nsColor: .windowBackgroundColor)))
                        renderer.scale = 2
                        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("card-\(choosing).png"))
                        }
                    }
                    if let view = front.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("window.png"))
                    }
                    exit(0)
                case "accountcard", "accountpicker":
                    // A sample account (no sign-in in a test home): the card as it opens, or with the pictures.
                    let host = NSHostingController(rootView: AccountCard(startEditing: what == "accountpicker"))
                    host.sizingOptions = [.preferredContentSize]
                    let window = NSWindow(contentViewController: host)
                    window.title = "Card"
                    window.makeKeyAndOrderFront(nil)
                default: if let page = InternalPage(rawValue: what) { front.showPage(page) }
                }
            }
        }
        #endif
    }

    private func sleepIdleTabs() {
        let minutes = Settings.sleepAfterMinutes
        guard minutes > 0 else { return }
        BrowserWindowController.all.forEach { $0.sleepIdleTabs(olderThan: TimeInterval(minutes * 60)) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        if !BrowserWindowController.all.filter({ !$0.isPrivate }).isEmpty { SessionStore.save() }
        HistoryStore.shared.saveNow()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { BrowserWindowController.newWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Opening links from other apps (default browser)

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else {
            launchURLs += urls
            return
        }
        open(urls)
    }

    private func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let target = BrowserWindowController.frontmost.flatMap { $0.isPrivate ? nil : $0 } ?? BrowserWindowController.newWindow()
        for url in urls {
            if let tab = target?.selectedTab, tab.isNewTabPage {
                target?.open(url, typed: false, disposition: .current)
            } else {
                target?.open(url, typed: false, disposition: .newTab)
            }
        }
        target?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: App-level actions

    @objc func newWindow(_ sender: Any?) { BrowserWindowController.newWindow() }
    @objc func newPrivateWindow(_ sender: Any?) { BrowserWindowController.newWindow(isPrivate: true) }

    /// ⌘T with no window open makes one.
    @objc func newTab(_ sender: Any?) { BrowserWindowController.newWindow() }

    /// ⌘⇧T with no window open.
    @objc func reopenClosedTab(_ sender: Any?) { RecentlyClosed.shared.reopen() }

    @objc func showHistory(_ sender: Any?) { (BrowserWindowController.frontmost ?? BrowserWindowController.newWindow())?.showPage(.history) }
    @objc func showDownloadsPage(_ sender: Any?) { (BrowserWindowController.frontmost ?? BrowserWindowController.newWindow())?.showPage(.downloads) }
    @objc func showFavoritesPage(_ sender: Any?) { (BrowserWindowController.frontmost ?? BrowserWindowController.newWindow())?.showPage(.favorites) }
    @objc func showPasswords(_ sender: Any?) { PasswordsWindowController.shared.showWindow(sender) }
    @objc func checkForUpdates(_ sender: Any?) { AppUpdater.shared.checkNow() }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.showWindow(sender) }

    @objc func setAsDefaultBrowser(_ sender: Any?) {
        let app = Bundle.main.bundleURL
        Task { @MainActor in
            for scheme in ["http", "https"] {
                try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
            }
            try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .html)
        }
    }

    @objc func importChromeBookmarks(_ sender: Any?) {
        let alert = NSAlert()
        if let count = BookmarkStore.shared.importFromChrome() {
            alert.messageText = count > 0 ? "Imported \(count) favorites from Chrome" : "Your Chrome favorites are already here"
        } else {
            alert.messageText = "No Chrome bookmarks found"
            alert.informativeText = "Chrome's bookmarks file was not found in ~/Library/Application Support/Google/Chrome."
        }
        alert.runModal()
    }

    @objc func importPasswords(_ sender: Any?) {
        PasswordsWindowController.shared.showWindow(sender)
    }

    @objc func clearBrowsingData(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Clear history, cookies and cache?"
        alert.informativeText = "You will be signed out of websites. Saved passwords and favorites stay."
        alert.addButton(withTitle: "Clear").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        WebEngine.shared.clearBrowsingData {
            BrowserWindowController.all.forEach { $0.refreshChrome() }
        }
    }

    // MARK: Menus

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            return item
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mask: NSEvent.ModifierFlags = .command,
                  tag: Int = 0, hidden: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            item.tag = tag
            if hidden {
                item.isHidden = true
                item.allowsKeyEquivalentWhenHidden = true
            }
            return item
        }
        let arrowRight = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let arrowLeft = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        typealias W = BrowserWindowController

        main.addItem(submenu("SheepBrowse", [
            item("About SheepBrowse", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Check for Updates…", #selector(checkForUpdates(_:))),
            item("Settings…", #selector(showSettings(_:)), ","),
            item("Set as Default Browser", #selector(setAsDefaultBrowser(_:))),
            item("Clear Browsing Data…", #selector(clearBrowsingData(_:)), "\u{8}", [.command, .shift]),
            .separator(),
            item("Hide SheepBrowse", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit SheepBrowse", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("File", [
            item("New Tab", #selector(W.newTab(_:)), "t"),
            item("New Window", #selector(newWindow(_:)), "n"),
            item("New Private Window", #selector(newPrivateWindow(_:)), "n", [.command, .shift]),
            item("Reopen Closed Tab", #selector(W.reopenClosedTab(_:)), "t", [.command, .shift]),
            item("Open Location…", #selector(W.openLocation(_:)), "l"),
            .separator(),
            item("Close Tab", #selector(W.closeTab(_:)), "w"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
            .separator(),
            item("Import Favorites from Chrome", #selector(importChromeBookmarks(_:))),
            item("Import Passwords…", #selector(importPasswords(_:))),
            .separator(),
            item("Print…", #selector(W.printPage(_:)), "p"),
        ]))
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            submenu("Find", [
                item("Find…", #selector(W.findInPage(_:)), "f"),
                item("Find Next", #selector(W.findNext(_:)), "g"),
                item("Find Previous", #selector(W.findPrevious(_:)), "g", [.command, .shift]),
            ]),
            submenu("AutoFill", [item("Passwords…", #selector(showPasswords(_:)))]),
        ]))
        main.addItem(submenu("View", [
            item("Hide Favorites Bar", #selector(W.toggleFavoritesBar(_:)), "b", [.command, .shift]),
            .separator(),
            item("Reload Page", #selector(W.reloadPage(_:)), "r"),
            item("Reload Without Cache", #selector(W.reloadFromOrigin(_:)), "r", [.command, .shift]),
            item("Stop", #selector(W.stopLoading(_:)), "."),
            .separator(),
            item("Zoom In", #selector(W.zoomIn(_:)), "+"),
            item("Zoom In", #selector(W.zoomIn(_:)), "=", hidden: true),
            item("Zoom Out", #selector(W.zoomOut(_:)), "-"),
            item("Actual Size", #selector(W.actualSize(_:)), "0"),
            .separator(),
            item("Translate Page", #selector(W.translatePage(_:)), "t", [.command, .option]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        let history = submenu("History", [
            item("Back", #selector(W.goBack(_:)), "["),
            item("Forward", #selector(W.goForward(_:)), "]"),
            item("Back", #selector(W.goBack(_:)), arrowLeft, .command, hidden: true),
            item("Forward", #selector(W.goForward(_:)), arrowRight, .command, hidden: true),
            .separator(),
            item("Home", #selector(W.goHome(_:)), "h", [.command, .shift]),
            item("Show All History", #selector(showHistory(_:)), "y"),
            item("Downloads", #selector(showDownloadsPage(_:)), "l", [.command, .option]),
            item("Downloads", #selector(showDownloadsPage(_:)), "j", [.command, .shift], hidden: true),
            .separator(),
        ])
        history.submenu?.delegate = self
        history.submenu?.identifier = .init("history")
        main.addItem(history)
        let favorites = submenu("Favorites", [
            item("Add to Favorites", #selector(W.toggleFavorite(_:)), "d"),
            item("Manage Favorites", #selector(showFavoritesPage(_:)), "b", [.command, .option]),
            item("Import from Chrome", #selector(importChromeBookmarks(_:))),
            .separator(),
        ])
        favorites.submenu?.delegate = self
        favorites.submenu?.identifier = .init("favorites")
        main.addItem(favorites)

        var tabItems: [NSMenuItem] = [
            item("Search Tabs…", #selector(W.searchTabs(_:)), "a", [.command, .shift]),
            .separator(),
            item("Select Next Tab", #selector(W.selectNextTab(_:)), "\t", .control),
            item("Select Previous Tab", #selector(W.selectPreviousTab(_:)), "\t", [.control, .shift]),
            item("Select Next Tab", #selector(W.selectNextTab(_:)), "]", [.command, .shift], hidden: true),
            item("Select Previous Tab", #selector(W.selectPreviousTab(_:)), "[", [.command, .shift], hidden: true),
            item("Select Next Tab", #selector(W.selectNextTab(_:)), arrowRight, [.command, .option], hidden: true),
            item("Select Previous Tab", #selector(W.selectPreviousTab(_:)), arrowLeft, [.command, .option], hidden: true),
            .separator(),
            item("Pin Tab", #selector(W.togglePinTab(_:))),
            item("Mute Tab", #selector(W.toggleMuteTab(_:)), "m", [.command, .control]),
            item("Duplicate Tab", #selector(W.duplicateTab(_:))),
            .separator(),
        ]
        for number in 1...9 {
            tabItems.append(item(number == 9 ? "Last Tab" : "Tab \(number)", #selector(W.selectTabByNumber(_:)), "\(number)", tag: number))
        }
        main.addItem(submenu("Tab", tabItems))

        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = window.submenu
        main.addItem(window)
        let help = submenu("Help", [])
        NSApp.helpMenu = help.submenu
        main.addItem(help)
        return main
    }

    /// Recent history and favorites, filled when the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let fixed = menu.identifier?.rawValue == "history" ? 10 : 4
        while menu.items.count > fixed { menu.removeItem(at: fixed) }
        let bar = FavoritesBarView()
        if menu.identifier?.rawValue == "history" {
            for entry in HistoryStore.shared.sorted.prefix(15) {
                guard let url = URL(string: entry.url) else { continue }
                let item = ClosureMenuItem(title: entry.title.isEmpty ? AddressInput.display(url) : String(entry.title.prefix(70))) {
                    (BrowserWindowController.frontmost ?? BrowserWindowController.newWindow())?.open(url, typed: false, disposition: .current)
                }
                let image = FaviconCache.shared.image(for: url.host) ?? NSImage.monogram(for: url.host)
                image.size = NSSize(width: 16, height: 16)
                item.image = image
                menu.addItem(item)
            }
        } else {
            for bookmark in BookmarkStore.shared.bar { menu.addItem(menuItem(for: bookmark, bar: bar)) }
        }
    }

    private func menuItem(for bookmark: Bookmark, bar: FavoritesBarView) -> NSMenuItem {
        if bookmark.isFolder {
            let item = NSMenuItem(title: bookmark.title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let sub = NSMenu()
            for child in bookmark.children ?? [] { sub.addItem(menuItem(for: child, bar: bar)) }
            item.submenu = sub
            return item
        }
        let url = bookmark.url.flatMap(URL.init(string:))
        let item = ClosureMenuItem(title: bookmark.title) {
            guard let url else { return }
            (BrowserWindowController.frontmost ?? BrowserWindowController.newWindow())?.open(url, typed: false, disposition: .current)
        }
        let image = FaviconCache.shared.image(for: url?.host) ?? NSImage.monogram(for: url?.host)
        image.size = NSSize(width: 16, height: 16)
        item.image = image
        return item
    }

    /// The ⋯ button's menu.
    func browserMenu(for controller: BrowserWindowController) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, _ action: Selector, _ target: AnyObject?, key: String = "",
                 mask: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            item.target = target
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        add("New Tab", "plus.square.on.square", #selector(BrowserWindowController.newTab(_:)), controller, key: "t")
        add("New Window", "macwindow.badge.plus", #selector(newWindow(_:)), self, key: "n")
        add("New Private Window", "hand.raised.fill", #selector(newPrivateWindow(_:)), self, key: "n", mask: [.command, .shift])
        menu.addItem(.separator())
        add("History", "clock.arrow.circlepath", #selector(showHistory(_:)), self, key: "y")
        add("Downloads", "arrow.down.circle", #selector(BrowserWindowController.showDownloadsPage(_:)), controller, key: "l", mask: [.command, .option])
        add("Favorites", "star", #selector(BrowserWindowController.showFavoritesPage(_:)), controller, key: "b", mask: [.command, .option])
        add("Passwords", "key.fill", #selector(showPasswords(_:)), self)
        add(BookmarkStore.shared.bookmark(for: controller.selectedTab?.url) == nil ? "Add to Favorites" : "Edit Favorite…",
            "star", #selector(BrowserWindowController.toggleFavorite(_:)), controller, key: "d")
        menu.addItem(.separator())
        let zoom = NSMenuItem()
        zoom.view = ZoomMenuRow(controller: controller)
        menu.addItem(zoom)
        menu.addItem(.separator())
        add("Find on Page…", "magnifyingglass", #selector(BrowserWindowController.findInPage(_:)), controller, key: "f")
        add("Translate Page", "translate", #selector(BrowserWindowController.translatePage(_:)), controller)
        add("Print…", "printer", #selector(BrowserWindowController.printPage(_:)), controller, key: "p")
        menu.addItem(.separator())
        add("Settings…", "gearshape", #selector(showSettings(_:)), self, key: ",")
        return menu
    }
}

/// Chrome's "Zoom  −  100%  +  ⛶" row in the ⋯ menu.
final class ZoomMenuRow: NSView {
    private weak var controller: BrowserWindowController?
    private let value = NSTextField(labelWithString: "100%")

    init(controller: BrowserWindowController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 30))
        let label = NSTextField(labelWithString: "Zoom")
        label.font = .menuFont(ofSize: 0)
        value.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        value.alignment = .center
        let minus = IconButton(symbol: "minus", label: "Zoom Out", target: self, action: #selector(zoomOut))
        let plus = IconButton(symbol: "plus", label: "Zoom In", target: self, action: #selector(zoomIn))
        let full = IconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Full Screen", target: self, action: #selector(fullScreen))
        for button in [minus, plus, full] { button.pointSize = 11; button.weight = .semibold }
        let stack = NSStackView(views: [label, NSView(), minus, value, plus, full])
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 8)
        stack.frame = bounds
        stack.autoresizingMask = [.width, .height]
        value.widthAnchor.constraint(equalToConstant: 46).isActive = true
        addSubview(stack)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        value.stringValue = "\(Int(round((controller?.selectedTab?.webView?.pageZoom ?? 1) * 100)))%"
    }

    @objc private func zoomIn() { controller?.zoomIn(nil); refresh() }
    @objc private func zoomOut() { controller?.zoomOut(nil); refresh() }
    @objc private func fullScreen() {
        enclosingMenuItem?.menu?.cancelTracking()
        controller?.window?.toggleFullScreen(nil)
    }
}

#if DEBUG
/// SHEEPBROWSE_DEBUG_OPEN=swipe: opens two pages, then feeds a two-finger swipe (trackpad scroll events
/// with phases) to the web view and logs whether it went back, and a pinch for the magnification.
enum SwipeTest {
    static func run(in controller: BrowserWindowController) {
        controller.open(URL(string: "https://example.com/")!, typed: true, disposition: .current)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            controller.open(URL(string: "https://example.org/")!, typed: true, disposition: .current)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { swipe(controller) }
        }
    }

    static func swipe(_ controller: BrowserWindowController) {
        guard let webView = controller.selectedTab?.webView, let window = webView.window else { return }
        NSLog("SWIPETEST before url=%@ canGoBack=%d gestures=%d magnify=%d", webView.url?.absoluteString ?? "-",
              webView.canGoBack ? 1 : 0, webView.allowsBackForwardNavigationGestures ? 1 : 0, webView.allowsMagnification ? 1 : 0)
        let local = webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
        let screen = window.convertPoint(toScreen: local)
        let flipped = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
        func post(_ dx: Int32, phase: Int64, delay: Double) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0) else { return }
                cg.location = flipped
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                if let event = NSEvent(cgEvent: cg) { window.sendEvent(event) }
            }
        }
        post(4, phase: 128 /* may begin */, delay: 0)
        post(6, phase: 1 /* began */, delay: 0.02)
        for i in 0..<30 { post(30, phase: 2 /* changed */, delay: 0.04 + Double(i) * 0.016) }
        post(0, phase: 4 /* ended */, delay: 0.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            NSLog("SWIPETEST after url=%@", webView.url?.absoluteString ?? "-")
            exit(0)
        }
    }
}
#endif
