import AppKit
import WebKit

/// One browser window: the glass header (tabs, navigation bar, favorites bar) floating over the page,
/// and the selected tab's content under it.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    static var all: [BrowserWindowController] = []

    let isPrivate: Bool
    /// A window a page opened with `window.open(…, "width=…")`: no tab strip.
    let isPopup: Bool
    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedIndex = 0
    var selectedTab: BrowserTab? { tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil }

    /// Where the next tab opened from the current page goes (Chrome: after the ones it already opened).
    private var childInsertOffset = 0

    private let root = RootView()
    private let contentArea = NSView()
    private let header = NSVisualEffectView()
    private let headerLine = NSBox()
    let tabStrip = TabStripView()
    private(set) var navBar: NavigationBarView!
    private let favoritesBar = FavoritesBarView()
    private lazy var newTabPage: NewTabPageView = {
        let page = NewTabPageView()
        page.onOpen = { [weak self] url, disposition in self?.open(url, typed: true, disposition: disposition) }
        return page
    }()
    private var findBar: FindBarView?
    /// The native pages (Downloads, Favorites, History) shown in tabs, by tab.
    private var pageViews: [UUID: (page: InternalPage, view: ListPageView)] = [:]
    private var certificateCard: CertificateCardView?
    private var saveCard: SavePasswordCard?
    private var pendingSaves: [UUID: (host: String, username: String, password: String)] = [:]
    private let loginPanel = SuggestionPanel()
    /// Site permission requests waiting for the bubble (one at a time).
    private var permissionQueue: [(tab: BrowserTab, origin: String, permissions: [SitePermission],
                                   answer: (PermissionPromptController.Answer) -> Void)] = []
    private var permissionPopover: NSPopover?
    private var permissionAnswer: ((PermissionPromptController.Answer) -> Void)?
    /// The request the bubble shows now (to merge a repeat of it, and to know whose it is).
    private var permissionShown: (tab: BrowserTab, origin: String, permissions: [SitePermission])?
    private var loginEntries: [SavedPassword] = []
    private var loginTab: BrowserTab?
    private var loginHost = ""
    /// The page's `location.origin` when the field was focused (checked again by the script before filling).
    private var loginOrigin = ""
    private var loginStrongPassword: String?

    private var stripHeight: CGFloat { isPopup ? 28 : TabStripView.height }
    /// The user's View ▸ Favorites Bar choice.
    private var favoritesBarWanted: Bool { UserDefaults.standard.object(forKey: "showFavoritesBar") as? Bool ?? true }
    /// The row appears only once there is a favorite to show.
    private var showsFavoritesBar: Bool { !isPopup && favoritesBarWanted && !BookmarkStore.shared.bar.isEmpty }
    var headerHeight: CGFloat {
        stripHeight + NavigationBarView.height + (showsFavoritesBar ? FavoritesBarView.height : 0)
    }

    // MARK: Creating windows

    init(isPrivate: Bool = false, isPopup: Bool = false, frame: NSRect? = nil) {
        self.isPrivate = isPrivate
        self.isPopup = isPopup
        let window = BrowserWindow(contentRect: frame ?? NSRect(x: 0, y: 0, width: 1280, height: 820),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty toolbar makes the title bar as tall as the tab row, so macOS itself centres the traffic
        // lights on the tabs (no moving of the window buttons).
        if !isPopup {
            let toolbar = NSToolbar(identifier: "SheepBrowseTitlebar")
            toolbar.showsBaselineSeparator = false
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
            window.toolbarStyle = .unifiedCompact
            window.titlebarSeparatorStyle = .none
        }
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        if isPrivate { window.appearance = NSAppearance(named: .darkAqua) }
        super.init(window: window)
        window.delegate = self
        navBar = NavigationBarView(controller: self)
        buildViews()
        if frame == nil {
            if let front = BrowserWindowController.frontmost?.window {
                window.setFrame(front.frame.offsetBy(dx: 26, dy: -26), display: false)
            } else if !window.setFrameUsingName("SheepBrowseWindow") {
                window.center()
            }
        }
        window.setFrameAutosaveName(isPopup ? "" : "SheepBrowseWindow")
        BrowserWindowController.all.append(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    static var frontmost: BrowserWindowController? {
        NSApp.orderedWindows.compactMap { $0.windowController as? BrowserWindowController }.first { !$0.isPopup }
    }

    @discardableResult
    static func newWindow(isPrivate: Bool = false, with tab: BrowserTab? = nil, frame: NSRect? = nil) -> BrowserWindowController? {
        let controller = BrowserWindowController(isPrivate: isPrivate, frame: frame)
        controller.insert(tab ?? controller.makeNewTab(), at: 0, select: true)
        controller.showWindow(nil)
        if controller.selectedTab?.isNewTabPage == true { controller.navBar.omnibox.beginEditing() }
        return controller
    }

    /// Brings a tab (in any window) to the front.
    static func reveal(_ tab: BrowserTab) {
        guard let controller = all.first(where: { $0.tabs.contains { $0 === tab } }) else { return }
        controller.select(tab)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func buildViews() {
        guard let window else { return }
        window.contentView = root
        root.onLayout = { [weak self] in self?.layoutViews() }
        root.addSubview(contentArea)

        header.material = .headerView
        header.blendingMode = .withinWindow
        header.state = .active
        root.addSubview(header)
        headerLine.boxType = .custom
        headerLine.fillColor = .separatorColor
        headerLine.borderWidth = 0
        header.addSubview(headerLine)

        tabStrip.delegate = self
        tabStrip.isHidden = isPopup
        tabStrip.accountButton.isHidden = isPrivate
        tabStrip.accountButton.onSignIn = { [weak self] in
            if let url = URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmail.google.com%2Fmail%2F") {
                self?.open(url, typed: false, disposition: self?.selectedTab?.isNewTabPage == true ? .current : .newTab)
            }
        }
        tabStrip.accountButton.onOpen = { [weak self] url in
            self?.open(url, typed: false, disposition: self?.selectedTab?.isNewTabPage == true ? .current : .newTab)
        }
        header.addSubview(tabStrip)
        header.addSubview(navBar)
        favoritesBar.delegate = self
        favoritesBar.isHidden = !showsFavoritesBar
        header.addSubview(favoritesBar)

        loginPanel.onPick = { [weak self] index in self?.pickLogin(index) }
        favoritesObserver = NotificationCenter.default.addObserver(forName: BookmarkStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutViews() }
        }
    }

    private var favoritesObserver: NSObjectProtocol?

    private func layoutViews() {
        let bounds = root.bounds
        contentArea.frame = bounds
        let headerHeight = self.headerHeight
        header.frame = NSRect(x: 0, y: bounds.height - headerHeight, width: bounds.width, height: headerHeight)
        headerLine.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1 / (window?.backingScaleFactor ?? 2))
        tabStrip.frame = NSRect(x: 0, y: headerHeight - stripHeight, width: bounds.width, height: stripHeight)
        tabStrip.leadingInset = trafficLightsInset()
        if let zoom = window?.standardWindowButton(.zoomButton), let superview = zoom.superview,
           window?.styleMask.contains(.fullScreen) == false {
            let frame = superview.convert(zoom.frame, to: tabStrip)
            tabStrip.centerFromTop = max(17, tabStrip.bounds.height - frame.midY)
        } else {
            tabStrip.centerFromTop = 20
        }
        navBar.frame = NSRect(x: 0, y: headerHeight - stripHeight - NavigationBarView.height,
                              width: bounds.width, height: NavigationBarView.height)
        favoritesBar.isHidden = !showsFavoritesBar
        favoritesBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: FavoritesBarView.height)

        let below = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - headerHeight)
        for view in contentArea.subviews {
            if let webView = view as? WKWebView, Settings.contentUnderToolbar {
                // The page runs under the glass header; WebKit keeps its content clear of it.
                webView.frame = bounds
                webView.obscuredContentInsets = NSEdgeInsets(top: headerHeight, left: 0, bottom: 0, right: 0)
            } else {
                view.frame = below
                (view as? WKWebView)?.obscuredContentInsets = NSEdgeInsets()
            }
        }
        if let findBar {
            findBar.frame = NSRect(x: bounds.width - 12 - 360, y: below.maxY - 10 - 36, width: 360, height: 36)
        }
        if let saveCard {
            let size = saveCard.preferredSize
            saveCard.frame = NSRect(x: bounds.width - 12 - size.width, y: below.maxY - 10 - size.height, width: size.width, height: size.height)
        }
    }

    private func trafficLightsInset() -> CGFloat {
        guard let zoom = window?.standardWindowButton(.zoomButton), let superview = zoom.superview else { return 80 }
        let frame = superview.convert(zoom.frame, to: tabStrip)
        return window?.styleMask.contains(.fullScreen) == true ? 12 : frame.maxX + 14
    }

    var currentContentView: NSView? {
        guard let tab = selectedTab else { return nil }
        return tab.webView ?? tab.internalPage.map { pageView(for: tab, page: $0) } ?? newTabPage
    }

    private func pageView(for tab: BrowserTab, page: InternalPage) -> ListPageView {
        if let cached = pageViews[tab.id], cached.page == page { return cached.view }
        let view = page.makeView { [weak self] url, disposition in self?.open(url, typed: false, disposition: disposition) }
        pageViews[tab.id] = (page, view)
        return view
    }

    /// Selects the tab already showing `page`, or opens it (in this tab when it is a new tab page).
    func showPage(_ page: InternalPage) {
        if let tab = tabs.first(where: { $0.internalPage == page }) {
            select(tab)
        } else if let tab = selectedTab, tab.isNewTabPage {
            tab.show(page)
        } else {
            let tab = BrowserTab(isPrivate: isPrivate)
            insert(tab, at: selectedIndex + 1, select: true)
            tab.show(page)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func showDownloadsPage(_ sender: Any?) { showPage(.downloads) }
    @objc func showFavoritesPage(_ sender: Any?) { showPage(.favorites) }
    @objc func showHistoryPage(_ sender: Any?) { showPage(.history) }

    // MARK: Tabs

    func insert(_ tab: BrowserTab, at index: Int, select: Bool) {
        tab.delegate = self
        let index = min(max(0, index), tabs.count)
        tabs.insert(tab, at: index)
        if select {
            selectedIndex = index
            childInsertOffset = 0
        } else if index <= selectedIndex && tabs.count > 1 {
            selectedIndex += 1
        }
        tabsChanged(animated: true)
        if select { showSelectedContent() }
    }

    func select(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        select(index: index)
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        if index != selectedIndex {
            selectedTab?.lastActive = Date()
            childInsertOffset = 0
        }
        selectedIndex = index
        tabsChanged(animated: false)
        showSelectedContent()
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        // The last tab closing the window is recorded with the window (as one tab).
        if !isPrivate && !tab.isNewTabPage && !AppDelegate.shared.isTerminating {
            RecentlyClosed.shared.add(ClosedItem(tab: tab.saved))
        }
        pendingSaves[tab.id] = nil
        pageViews[tab.id] = nil
        tab.close()
        tabs.remove(at: index)
        if tabs.isEmpty {
            window?.close()
            return
        }
        if index < selectedIndex || selectedIndex >= tabs.count { selectedIndex = max(0, selectedIndex - 1) }
        tabsChanged(animated: true)
        showSelectedContent()
    }

    /// Takes the tab out of this window without closing it (to move it elsewhere).
    private func remove(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.webView?.removeFromSuperview()
        pageViews[tab.id] = nil
        tabs.remove(at: index)
        if tabs.isEmpty {
            window?.close()
            return
        }
        if index < selectedIndex || selectedIndex >= tabs.count { selectedIndex = max(0, selectedIndex - 1) }
        tabsChanged(animated: true)
        showSelectedContent()
    }

    private func tabsChanged(animated: Bool) {
        tabStrip.reload(tabs: tabs, selected: selectedTab, animated: animated)
        refreshChrome()
        if !isPrivate { SessionStore.scheduleSave() }
    }

    /// Puts the selected tab's page (or the new tab page) under the header.
    private func showSelectedContent() {
        guard let tab = selectedTab else { return }
        if tab.isAsleep { tab.wake() }
        let content: NSView = tab.webView ?? tab.internalPage.map { pageView(for: tab, page: $0) } ?? newTabPage
        for view in contentArea.subviews where view !== content { view.removeFromSuperview() }
        if content.superview !== contentArea { contentArea.addSubview(content, positioned: .below, relativeTo: nil) }
        showCertificateCard(for: tab)
        showSaveCard(for: tab)
        loginPanel.hide()
        if permissionPopover != nil, permissionShown?.tab !== tab { finishPermission(.dismissed) }
        if let findBar { contentArea.addSubview(findBar) }
        layoutViews()
        if tab.isNewTabPage {
            newTabPage.reload()
            navBar.omnibox.beginEditing()
        } else if window?.firstResponder === navBar.omnibox.field.currentEditor() {
            window?.makeFirstResponder(content)
        } else {
            window?.makeFirstResponder(content)
        }
        refreshChrome()
    }

    func relayout() { layoutViews() }

    func refreshChrome() {
        let tab = selectedTab
        navBar.update(for: tab)
        window?.title = tab?.title ?? "SheepBrowse"
        tabStrip.refreshAll()
    }

    /// Opens a URL the user asked for.
    func open(_ url: URL, typed: Bool, disposition: OpenDisposition, upgraded: Bool = false) {
        // A popup has no tab strip: a tab opened from it goes to the main window (where it can be seen).
        if isPopup && disposition != .current {
            let target = BrowserWindowController.all.first { !$0.isPopup && $0.isPrivate == isPrivate && $0.window?.isVisible == true }
                ?? BrowserWindowController.newWindow(isPrivate: isPrivate)
            target?.open(url, typed: typed, disposition: disposition == .newWindow ? .newWindow : .newTab, upgraded: upgraded)
            target?.window?.makeKeyAndOrderFront(nil)
            return
        }
        switch disposition {
        case .current:
            guard let tab = selectedTab else { return }
            let wasNative = tab.webView == nil
            tab.load(url, typed: typed, upgraded: upgraded)
            if wasNative { showSelectedContent() }
        case .newTab, .backgroundTab:
            let tab = BrowserTab(isPrivate: isPrivate)
            let background = disposition == .backgroundTab
            insert(tab, at: selectedIndex + 1 + childInsertOffset, select: !background)
            if background { childInsertOffset += 1 }
            tab.load(url, typed: typed, upgraded: upgraded)
            if !background { showSelectedContent() }
        case .newWindow:
            let tab = BrowserTab(isPrivate: isPrivate)
            tab.load(url, typed: typed, upgraded: upgraded)
            BrowserWindowController.newWindow(isPrivate: isPrivate, with: tab)
        }
    }

    func openRestored(_ saved: [SavedTab], selected: Int) {
        for (index, item) in saved.enumerated() {
            let tab = BrowserTab(saved: item)
            tab.delegate = self
            tabs.append(tab)
            if index == selected { selectedIndex = index }
        }
        if tabs.isEmpty { tabs.append(BrowserTab()); tabs[0].delegate = self }
        tabsChanged(animated: false)
        showSelectedContent()
    }

    // MARK: Background tabs

    func sleepIdleTabs(olderThan interval: TimeInterval) {
        for tab in tabs where tab !== selectedTab && !tab.isAsleep && Date().timeIntervalSince(tab.lastActive) > interval {
            tab.sleepIfIdle()
        }
    }

    // MARK: Window delegate

    func windowWillClose(_ notification: Notification) {
        loginPanel.hide()
        // Every waiting request gets its answer (WebKit waits on each one).
        let waiting = permissionQueue
        permissionQueue.removeAll()
        if permissionPopover != nil { finishPermission(.dismissed) }
        waiting.forEach { $0.answer(.dismissed) }
        // Closing a window with several tabs can be undone with ⌘⇧T (Chrome).
        if !isPrivate && !isPopup && !AppDelegate.shared.isTerminating, let window {
            if tabs.count > 1 {
                RecentlyClosed.shared.add(ClosedItem(window: SavedWindow(frame: NSStringFromRect(window.frame),
                                                                         tabs: tabs.map(\.saved), selected: selectedIndex)))
            } else if let only = tabs.first, !only.isNewTabPage {
                RecentlyClosed.shared.add(ClosedItem(tab: only.saved))
            }
        }
        if BrowserWindowController.all.count == 1 && !isPrivate { SessionStore.save() }
        for tab in tabs { tab.close() }
        tabs.removeAll()
        BrowserWindowController.all.removeAll { $0 === self }
        if isPrivate { WebEngine.shared.privateWindowsClosed() }
        if !isPrivate { SessionStore.scheduleSave() }
    }

    func windowDidResize(_ notification: Notification) { loginPanel.hide() }
    // In full screen macOS draws the (empty) toolbar as an opaque band over the top of the window, which
    // hid the tabs: the toolbar is off while in full screen (the tabs sit at the very top, as in Chrome).
    func windowWillEnterFullScreen(_ notification: Notification) { window?.toolbar?.isVisible = false }
    func windowDidEnterFullScreen(_ notification: Notification) { layoutViews() }
    func windowWillExitFullScreen(_ notification: Notification) { window?.toolbar?.isVisible = true }
    func windowDidExitFullScreen(_ notification: Notification) { layoutViews() }

    func windowDidBecomeKey(_ notification: Notification) {
        tabStrip.refreshAll()
        (permissionPopover?.contentViewController as? PermissionPromptController)?.rearm()
    }
}

// MARK: - Tab delegate

extension BrowserWindowController: BrowserTabDelegate {
    func tabDidChange(_ tab: BrowserTab) {
        tabStrip.refresh(tab)
        if tab === selectedTab {
            navBar.update(for: tab)
            window?.title = tab.title
            showCertificateCard(for: tab)
            if let webView = tab.webView, webView.superview !== contentArea { showSelectedContent() }
        }
        if !isPrivate { SessionStore.scheduleSave() }
    }

    func tabWebViewDidChange(_ tab: BrowserTab) {
        if pageViews[tab.id]?.page != tab.internalPage { pageViews[tab.id] = nil }
        if tab === selectedTab { showSelectedContent() }
    }

    func tabIsSelected(_ tab: BrowserTab) -> Bool {
        tab === selectedTab && window?.isVisible == true
    }

    func tab(_ tab: BrowserTab, open url: URL, background: Bool) {
        if tab !== selectedTab, let index = tabs.firstIndex(where: { $0 === tab }) { select(index: index) }
        open(url, typed: false, disposition: background ? .backgroundTab : .newTab)
    }

    func tab(_ tab: BrowserTab, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
             features: WKWindowFeatures) -> WKWebView? {
        let fromContextMenu = SheepWebView.contextMenuNewTabAt.map { Date().timeIntervalSince($0) < 1 } ?? false
        SheepWebView.contextMenuNewTabAt = nil
        let newTab = BrowserTab(configuration: configuration, isPrivate: isPrivate)

        // A sized window.open (sign-in with Google, a payment page): a small popup window, as in Chrome.
        if !fromContextMenu, let width = features.width?.doubleValue, let height = features.height?.doubleValue {
            let screen = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let size = NSSize(width: max(360, min(width, screen.width)), height: max(300, min(height + headerHeight, screen.height)))
            // The page may ask for any x: keep the popup on screen (never parked under the cursor or off-screen).
            let wantedX = features.x?.doubleValue ?? (window?.frame.midX ?? screen.midX) - size.width / 2
            let origin = NSPoint(x: min(max(wantedX, screen.minX), max(screen.minX, screen.maxX - size.width)),
                                 y: (window?.frame.midY ?? screen.midY) - size.height / 2)
            let popup = BrowserWindowController(isPrivate: isPrivate, isPopup: true, frame: NSRect(origin: origin, size: size))
            popup.insert(newTab, at: 0, select: true)
            popup.showWindow(nil)
            return newTab.webView
        }
        if isPopup, let main = BrowserWindowController.all.first(where: { !$0.isPopup && $0.isPrivate == isPrivate && $0.window?.isVisible == true }) {
            main.insert(newTab, at: main.tabs.count, select: true)
            main.window?.makeKeyAndOrderFront(nil)
            return newTab.webView
        }
        let background = fromContextMenu
        insert(newTab, at: selectedIndex + 1 + childInsertOffset, select: !background)
        if background { childInsertOffset += 1 }
        return newTab.webView
    }

    func tabRequestsClose(_ tab: BrowserTab) {
        close(tab)
    }
}

// MARK: - Tab strip delegate

extension BrowserWindowController: TabStripDelegate {
    func tabStripSelect(_ tab: BrowserTab) { select(tab) }
    func tabStripClose(_ tab: BrowserTab) { close(tab) }
    func tabStripNewTab() { newTab(nil) }
    func tabStripToggleMute(_ tab: BrowserTab) { tab.setMuted(!tab.isMuted) }
    func tabStripSearch(from button: NSView) {
        guard let window else { return }
        TabSearchController.shared.show(below: button, in: window)
    }

    func tabStripMove(_ tab: BrowserTab, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        let selected = selectedTab
        tabs.remove(at: from)
        tabs.insert(tab, at: index)
        if let selected, let newIndex = tabs.firstIndex(where: { $0 === selected }) { selectedIndex = newIndex }
        if !isPrivate { SessionStore.scheduleSave() }
    }

    func tabStripDetach(_ tab: BrowserTab, at screenPoint: NSPoint) {
        // Dropped on a Favorites bar: the page becomes a favorite (the tab stays).
        for controller in BrowserWindowController.all where controller.showsFavoritesBar && !controller.favoritesBar.isHidden {
            guard let window = controller.window,
                  window.convertToScreen(controller.favoritesBar.convert(controller.favoritesBar.bounds, to: nil)).contains(screenPoint) else { continue }
            if let url = tab.url, ["http", "https"].contains(url.scheme ?? "") { BookmarkStore.shared.add(url: url, title: tab.title) }
            return
        }
        // Dropped on another window's tab strip: move it there.
        if let target = BrowserWindowController.all.first(where: { other in
            other !== self && !other.isPopup && other.isPrivate == isPrivate && other.window?.isVisible == true &&
                other.stripScreenRect.contains(screenPoint)
        }) {
            remove(tab)
            target.insert(tab, at: target.tabs.count, select: true)
            target.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard tabs.count > 1 else { return }
        remove(tab)
        let size = window?.frame.size ?? NSSize(width: 1100, height: 760)
        let frame = NSRect(x: screenPoint.x - 120, y: screenPoint.y - size.height + 20, width: size.width, height: size.height)
        BrowserWindowController.newWindow(isPrivate: isPrivate, with: tab, frame: frame)
    }

    private var stripScreenRect: NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(tabStrip.convert(tabStrip.bounds, to: nil)).insetBy(dx: 0, dy: -10)
    }

    func tabStripMenu(for tab: BrowserTab) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "New Tab to the Right") { [weak self] in
            guard let self, let index = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.insert(self.makeNewTab(), at: index + 1, select: true)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Reload") { if let webView = tab.webView { webView.reload() } else { tab.wake() } })
        menu.addItem(ClosureMenuItem(title: "Duplicate") { [weak self] in self?.duplicate(tab) })
        menu.addItem(ClosureMenuItem(title: tab.isPinned ? "Unpin" : "Pin") { [weak self] in self?.togglePin(tab) })
        menu.addItem(ClosureMenuItem(title: tab.isMuted ? "Unmute Site" : "Mute Site") { tab.setMuted(!tab.isMuted) })
        menu.addItem(ClosureMenuItem(title: "Move to New Window") { [weak self] in
            guard let self, self.tabs.count > 1 else { return }
            self.remove(tab)
            BrowserWindowController.newWindow(isPrivate: self.isPrivate, with: tab)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Close Tab") { [weak self] in self?.close(tab) })
        menu.addItem(ClosureMenuItem(title: "Close Other Tabs") { [weak self] in
            self?.tabs.filter { $0 !== tab && !$0.isPinned }.forEach { self?.close($0) }
        })
        menu.addItem(ClosureMenuItem(title: "Close Tabs to the Right") { [weak self] in
            guard let self, let index = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.tabs[(index + 1)...].filter { !$0.isPinned }.forEach { self.close($0) }
        })
        return menu
    }

    private func duplicate(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        let copy = BrowserTab(saved: tab.saved, isPrivate: isPrivate)
        insert(copy, at: index + 1, select: true)
    }

    private func togglePin(_ tab: BrowserTab) {
        tab.isPinned.toggle()
        // Pinned tabs sit together at the left.
        let pinned = tabs.filter(\.isPinned)
        let others = tabs.filter { !$0.isPinned }
        let selected = selectedTab
        tabs = pinned + others
        if let selected { selectedIndex = tabs.firstIndex { $0 === selected } ?? 0 }
        tabsChanged(animated: true)
    }
}

// MARK: - Favorites bar delegate

extension BrowserWindowController: FavoritesBarDelegate {
    func favoritesBar(open url: URL, disposition: OpenDisposition) {
        open(url, typed: false, disposition: disposition)
    }
}

// MARK: - Actions (menus, toolbar, keys)

extension BrowserWindowController: NSMenuItemValidation {
    @objc func newTab(_ sender: Any?) {
        if isPopup {
            (BrowserWindowController.frontmost ?? BrowserWindowController.newWindow(isPrivate: isPrivate))?.newTab(sender)
            return
        }
        insert(makeNewTab(), at: tabs.count, select: true)
        showSelectedContent()
    }

    /// A new tab as Settings → New tabs open says: the start page, Google, or a page.
    func makeNewTab() -> BrowserTab {
        let tab = BrowserTab(isPrivate: isPrivate)
        if let url = Settings.newTabPageURL {
            tab.delegate = self
            tab.load(url)
        }
        return tab
    }

    @objc func goHome(_ sender: Any?) {
        guard let url = AddressInput.url(for: Settings.homeURL) else { return }
        open(url, typed: false, disposition: .current)
    }

    @objc func closeTab(_ sender: Any?) {
        if let tab = selectedTab { close(tab) }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        RecentlyClosed.shared.reopen()
    }

    /// Puts a closed tab back, after the selected one (or into an empty new tab).
    func reopen(_ saved: SavedTab) {
        let tab = BrowserTab(saved: saved)
        if let current = selectedTab, current.isNewTabPage, let index = tabs.firstIndex(where: { $0 === current }) {
            // Insert first: closing the only tab first would close (and forget) this window.
            insert(tab, at: index + 1, select: true)
            close(current)
        } else {
            insert(tab, at: selectedIndex + 1, select: true)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func selectNextTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        select(index: (selectedIndex + 1) % tabs.count)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        select(index: (selectedIndex - 1 + tabs.count) % tabs.count)
    }

    /// ⌘1…⌘8 pick that tab; ⌘9 the last one (Chrome).
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        let number = sender.tag
        select(index: number == 9 ? tabs.count - 1 : min(number - 1, tabs.count - 1))
    }

    @objc func openLocation(_ sender: Any?) {
        if isPopup { return }
        navBar.omnibox.beginEditing()
    }

    @objc func searchTabs(_ sender: Any?) {
        if let window { TabSearchController.shared.show(below: tabStrip.searchButton, in: window) }
    }

    @objc func goBack(_ sender: Any?) { selectedTab?.webView?.goBack() }
    @objc func goForward(_ sender: Any?) { selectedTab?.webView?.goForward() }

    @objc func reloadOrStop(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        if tab.isLoading { tab.webView?.stopLoading() } else { reloadPage(sender) }
    }

    @objc func reloadPage(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        if let webView = tab.webView { webView.reload() } else if let url = tab.url { tab.load(url) }
    }

    @objc func reloadFromOrigin(_ sender: Any?) { selectedTab?.webView?.reloadFromOrigin() }
    @objc func stopLoading(_ sender: Any?) { selectedTab?.webView?.stopLoading() }

    @objc func zoomIn(_ sender: Any?) { selectedTab?.zoom(1) }
    @objc func zoomOut(_ sender: Any?) { selectedTab?.zoom(-1) }
    @objc func actualSize(_ sender: Any?) { selectedTab?.zoom(0) }

    @objc func toggleFavoritesBar(_ sender: Any?) {
        UserDefaults.standard.set(!favoritesBarWanted, forKey: "showFavoritesBar")
        for controller in BrowserWindowController.all {
            controller.favoritesBar.isHidden = !controller.showsFavoritesBar
            controller.layoutViews()
        }
    }

    @objc func toggleFavorite(_ sender: Any?) {
        guard let tab = selectedTab, let url = tab.url else { return }
        if let existing = BookmarkStore.shared.bookmark(for: url) {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = FavoriteEditor(bookmark: existing)
            popover.show(relativeTo: navBar.omnibox.starButton.bounds, of: navBar.omnibox.starButton, preferredEdge: .maxY)
        } else {
            BookmarkStore.shared.add(url: url, title: tab.title)
            if !favoritesBarWanted { toggleFavoritesBar(nil) }
        }
        refreshChrome()
    }

    @objc func findInPage(_ sender: Any?) {
        guard selectedTab?.webView != nil else { return }
        if findBar == nil {
            let bar = FindBarView()
            bar.onFind = { [weak self] text, backwards in self?.find(text, backwards: backwards) }
            bar.onClose = { [weak self] in self?.closeFind() }
            findBar = bar
        }
        if let findBar {
            contentArea.addSubview(findBar)
            layoutViews()
            window?.makeFirstResponder(findBar.field)
            findBar.field.currentEditor()?.selectAll(nil)
        }
    }

    @objc func findNext(_ sender: Any?) { find(findBar?.field.stringValue ?? "", backwards: false) }
    @objc func findPrevious(_ sender: Any?) { find(findBar?.field.stringValue ?? "", backwards: true) }

    private func find(_ text: String, backwards: Bool) {
        guard let webView = selectedTab?.webView, !text.isEmpty else {
            findBar?.showResult(found: true)
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        webView.find(text, configuration: configuration) { [weak self] result in
            MainActor.assumeIsolated { self?.findBar?.showResult(found: result.matchFound) }
        }
    }

    private func closeFind() {
        findBar?.removeFromSuperview()
        findBar = nil
        if let content = currentContentView { window?.makeFirstResponder(content) }
    }

    @objc func printPage(_ sender: Any?) {
        guard let webView = selectedTab?.webView, let window else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func togglePinTab(_ sender: Any?) { if let tab = selectedTab { togglePin(tab) } }
    @objc func toggleMuteTab(_ sender: Any?) { if let tab = selectedTab { tab.setMuted(!tab.isMuted) } }
    @objc func duplicateTab(_ sender: Any?) { if let tab = selectedTab { duplicate(tab) } }

    @objc func translatePage(_ sender: Any?) {
        guard let tab = selectedTab, let webView = tab.webView else { return }
        PageTranslator.translate(webView, in: self)
    }

    @objc func showDownloads(_ sender: Any?) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = DownloadsViewController()
        let anchor: NSView = navBar.downloadsButton.isHidden ? navBar.menuButton : navBar.downloadsButton
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    @objc func showSiteInfo(_ sender: Any?) {
        guard let tab = selectedTab, tab.url != nil, !tab.isNewTabPage else {
            navBar.omnibox.beginEditing()
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = SiteInfoViewController(tab: tab, controller: self)
        popover.show(relativeTo: navBar.omnibox.siteButton.bounds, of: navBar.omnibox.siteButton, preferredEdge: .minY)
    }

    @objc func showShieldMenu(_ sender: Any?) {
        let menu = NSMenu()
        let everywhere = ClosureMenuItem(title: "Block Ads and Trackers") {
            Settings.blockAds.toggle()
            WebEngine.shared.refreshBlockList()
            BrowserWindowController.all.forEach { $0.refreshChrome() }
        }
        everywhere.state = Settings.blockAds ? .on : .off
        menu.addItem(everywhere)
        if let site = AddressInput.site(of: selectedTab?.url?.host), Settings.blockAds {
            let allowed = Settings.adBlockAllowedSites.contains(site)
            let item = ClosureMenuItem(title: "Block on \(site)") { [weak self] in
                var sites = Settings.adBlockAllowedSites
                if allowed { sites.remove(site) } else { sites.insert(site) }
                Settings.adBlockAllowedSites = sites
                WebEngine.shared.refreshBlockList()
                self?.selectedTab?.webView?.reload()
                self?.refreshChrome()
            }
            item.state = allowed ? .off : .on
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: navBar.shieldButton.bounds.height + 6), in: navBar.shieldButton)
    }

    @objc func showMainMenu(_ sender: Any?) {
        let menu = AppDelegate.shared.browserMenu(for: self)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: navBar.menuButton.bounds.height + 6), in: navBar.menuButton)
    }

    func showHistoryMenu(back: Bool, from button: NSView) {
        guard let webView = selectedTab?.webView else { return }
        let list = back ? webView.backForwardList.backList.reversed() : webView.backForwardList.forwardList
        let menu = NSMenu()
        for item in list.prefix(20) {
            let entry = ClosureMenuItem(title: item.title?.isEmpty == false ? item.title! : item.url.absoluteString) {
                webView.go(to: item)
            }
            let image = FaviconCache.shared.image(for: item.url.host) ?? NSImage.monogram(for: item.url.host)
            image.size = NSSize(width: 16, height: 16)
            entry.image = image
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 6), in: button)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let tab = selectedTab
        switch item.action {
        case #selector(goBack(_:)): return tab?.canGoBack ?? false
        case #selector(goForward(_:)): return tab?.canGoForward ?? false
        case #selector(reopenClosedTab(_:)): return !RecentlyClosed.shared.items.isEmpty
        case #selector(findInPage(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)), #selector(printPage(_:)),
             #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualSize(_:)), #selector(translatePage(_:)):
            return tab?.webView != nil
        case #selector(toggleFavoritesBar(_:)):
            item.title = favoritesBarWanted ? "Hide Favorites Bar" : "Show Favorites Bar"
            return !isPopup
        case #selector(toggleFavorite(_:)):
            item.title = BookmarkStore.shared.bookmark(for: tab?.url) == nil ? "Add to Favorites" : "Edit Favorite…"
            return tab?.url != nil
        case #selector(togglePinTab(_:)):
            item.title = tab?.isPinned == true ? "Unpin Tab" : "Pin Tab"
            return tab != nil && !isPopup
        case #selector(toggleMuteTab(_:)):
            item.title = tab?.isMuted == true ? "Unmute Tab" : "Mute Tab"
            return tab?.webView != nil
        case #selector(selectTabByNumber(_:)): return tabs.count > 1
        default: return true
        }
    }
}

// MARK: - Certificates and passwords on the page

extension BrowserWindowController {
    private func showCertificateCard(for tab: BrowserTab) {
        guard tab === selectedTab, let issue = tab.certificateIssue else {
            if certificateCard?.superview != nil {
                certificateCard?.removeFromSuperview()
                certificateCard = nil
            }
            return
        }
        let card = certificateCard ?? CertificateCardView()
        certificateCard = card
        card.onAnswer = { [weak tab] trust, once in tab?.resolveCertificate(trust: trust, once: once) }
        card.show(issue)
        if card.superview == nil { contentArea.addSubview(card) }
        layoutViews()
    }

    /// The bubble under the site icon: "meet.google.com wants to use your camera".
    func askPermission(for tab: BrowserTab, origin: String, permissions: [SitePermission],
                       answer: @escaping (PermissionPromptController.Answer) -> Void) {
        // The same question again (a page calling twice, a burst of requestPermission()): one bubble answers all.
        if let shown = permissionShown, shown.tab === tab, shown.origin == origin, shown.permissions == permissions,
           let first = permissionAnswer {
            permissionAnswer = { first($0); answer($0) }
            return
        }
        if let index = permissionQueue.firstIndex(where: { $0.tab === tab && $0.origin == origin && $0.permissions == permissions }) {
            let first = permissionQueue[index].answer
            permissionQueue[index].answer = { first($0); answer($0) }
            return
        }
        permissionQueue.append((tab, origin, permissions, answer))
        if permissionPopover == nil { showNextPermission() }
    }

    private func showNextPermission() {
        guard !permissionQueue.isEmpty else { return }
        let request = permissionQueue.removeFirst()
        guard request.tab === selectedTab, window?.isVisible == true else {
            request.answer(.dismissed)
            return showNextPermission()
        }
        // Answered meanwhile (Settings, Site Info, an earlier bubble): no question to ask.
        if let known = request.tab.currentDecision(request.permissions, origin: request.origin) {
            request.answer(.decided(known))
            return showNextPermission()
        }
        let prompt = PermissionPromptController(origin: request.origin, permissions: request.permissions)
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.contentViewController = prompt
        permissionAnswer = request.answer
        permissionShown = (request.tab, request.origin, request.permissions)
        // A click that lands on this bubble as it fades out must not answer the next one.
        prompt.onAnswer = { [weak self, weak popover] answer in
            guard let self, let popover, popover === self.permissionPopover else { return }
            self.finishPermission(answer)
        }
        permissionPopover = popover
        popover.show(relativeTo: navBar.omnibox.siteButton.bounds, of: navBar.omnibox.siteButton, preferredEdge: .minY)
    }

    /// Answered, or the tab went away / out of view (= not allowed).
    private func finishPermission(_ answer: PermissionPromptController.Answer) {
        let callback = permissionAnswer
        permissionAnswer = nil
        permissionShown = nil
        permissionPopover?.close()
        permissionPopover = nil
        callback?(answer)
        refreshChrome()
        showNextPermission()
    }

    func passwordField(focusedIn tab: BrowserTab, host: String, origin: String, cssRect: CGRect, newPassword: Bool) {
        guard tab === selectedTab, let webView = tab.webView, let window else { return }
        loginEntries = PasswordStore.shared.entries(forKey: host)
        loginTab = tab
        loginHost = host
        loginOrigin = origin
        loginStrongPassword = newPassword && loginEntries.isEmpty ? StrongPassword.generate() : nil
        guard !loginEntries.isEmpty || loginStrongPassword != nil else { return loginPanel.hide() }

        // CSS pixels of the viewport → the web view's points (page zoom and pinch both scale them).
        let scale = webView.pageZoom * webView.magnification
        let top = webView.obscuredContentInsets.top
        var rect = NSRect(x: cssRect.minX * scale, y: top + cssRect.minY * scale, width: cssRect.width * scale, height: cssRect.height * scale)
        if !webView.isFlipped { rect.origin.y = webView.bounds.height - rect.maxY }
        let screenRect = window.convertToScreen(webView.convert(rect, to: nil))

        var items = loginEntries.map { entry in
            let iconHost = LoginKey.host(of: entry.host)
            let image = FaviconCache.shared.image(for: iconHost) ?? NSImage.monogram(for: iconHost)
            return SuggestionItem(image: image, title: entry.username.isEmpty ? "(no user name)" : entry.username,
                                  subtitle: entry.host, tiled: true)
        }
        if let strong = loginStrongPassword {
            items.append(SuggestionItem(symbol: "key.viewfinder", title: "Use Strong Password", subtitle: strong, tiled: false))
        }
        loginPanel.footer = LoginFooterView(onPasswords: { PasswordsWindowController.shared.showWindow(nil) })
        loginPanel.show(items, below: screenRect, width: max(300, min(screenRect.width, 380)), parent: window, select: nil)
    }

    func passwordFieldBlurred(in tab: BrowserTab) {
        // The click that picks a row blurs the field first; give it a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, NSApp.currentEvent?.window !== self.loginPanel else { return }
            if NSEvent.pressedMouseButtons == 0 { self.loginPanel.hide() }
        }
    }

    private func pickLogin(_ index: Int) {
        loginPanel.hide()
        guard let tab = loginTab, let webView = tab.webView else { return }
        let host = loginHost
        let origin = loginOrigin
        if index >= loginEntries.count, let strong = loginStrongPassword {
            webView.callAsyncJavaScript("return window.__sheepFillNew(pass, expected);", arguments: ["pass": strong, "expected": origin],
                                        in: nil, in: PasswordAutofill.world, completionHandler: nil)
            return
        }
        guard index < loginEntries.count else { return }
        let entry = loginEntries[index]
        Task { @MainActor in
            guard await PasswordStore.shared.authenticate(reason: "fill your password for \(host)") else { return }
            PasswordAutofill.fill(entry, in: webView, expectedOrigin: origin)
            PasswordStore.shared.markUsed(entry.id)
        }
    }

    func offerToSavePassword(tab: BrowserTab, host: String, username: String, password: String) {
        guard !PasswordNever.contains(host),
              PasswordStore.shared.kind(host: host, username: username, password: password) != .same else { return }
        pendingSaves[tab.id] = (host, username, password)
        if tab === selectedTab { showSaveCard(for: tab) }
    }

    private func showSaveCard(for tab: BrowserTab) {
        saveCard?.removeFromSuperview()
        saveCard = nil
        guard let pending = pendingSaves[tab.id] else { return }
        let update = PasswordStore.shared.kind(host: pending.host, username: pending.username, password: pending.password) == .update
        let card = SavePasswordCard(host: pending.host, username: pending.username, update: update)
        card.onAnswer = { [weak self, weak tab] answer in
            guard let self, let tab else { return }
            switch answer {
            case .save: PasswordStore.shared.save(host: pending.host, username: pending.username, password: pending.password)
            case .never: PasswordNever.add(pending.host)
            case .notNow: break
            }
            self.pendingSaves[tab.id] = nil
            self.saveCard?.removeFromSuperview()
            self.saveCard = nil
        }
        saveCard = card
        contentArea.addSubview(card)
        layoutViews()
    }
}

/// Sites the user said "Never" to.
enum PasswordNever {
    static func contains(_ host: String) -> Bool { (UserDefaults.standard.stringArray(forKey: "passwordNever") ?? []).contains(host) }
    static func add(_ host: String) {
        var list = UserDefaults.standard.stringArray(forKey: "passwordNever") ?? []
        list.append(host)
        UserDefaults.standard.set(list, forKey: "passwordNever")
    }
}

/// Apple's strong password shape: three groups of six, letters with one digit and one capital.
enum StrongPassword {
    static func generate() -> String {
        let lower = Array("abcdefghijkmnopqrstuvwxyz"), upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ"), digits = Array("23456789")
        var chars = (0..<18).map { _ in lower.randomElement()! }
        var positions = Array(0..<18).shuffled()
        chars[positions.removeFirst()] = upper.randomElement()!
        chars[positions.removeFirst()] = digits.randomElement()!
        let text = String(chars)
        return [text.prefix(6), text.dropFirst(6).prefix(6), text.suffix(6)].joined(separator: "-")
    }
}

/// The footer under saved logins: Touch ID hint and a way to the Passwords window.
final class LoginFooterView: NSView {
    private let onPasswords: () -> Void

    init(onPasswords: @escaping () -> Void) {
        self.onPasswords = onPasswords
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        let touch = NSImageView(image: NSImage(systemSymbolName: "touchid", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))!)
        touch.contentTintColor = .systemPink
        let hint = NSTextField(labelWithString: "Fill with Touch ID")
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = .secondaryLabelColor
        let button = NSButton(title: "Passwords…", target: self, action: #selector(open))
        button.isBordered = false
        button.font = .systemFont(ofSize: 11.5, weight: .medium)
        button.contentTintColor = .controlAccentColor
        let row = NSStackView(views: [touch, hint, NSView(), button])
        row.spacing = 6
        for view in [line, row] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            line.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func open() { onPasswords() }
}

/// Name / remove for a page that is already a favorite.
final class FavoriteEditor: NSViewController {
    private let bookmark: Bookmark
    private let field = NSTextField()

    init(bookmark: Bookmark) {
        self.bookmark = bookmark
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: "Favorite")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        field.stringValue = bookmark.title
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeFavorite))
        remove.bezelStyle = .glass
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.bezelStyle = .glass
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [remove, NSView(), done])
        let stack = NSStackView(views: [title, field, buttons]).vertical()
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        buttons.widthAnchor.constraint(equalTo: field.widthAnchor).isActive = true
        view = stack
    }

    @objc private func removeFavorite() {
        BookmarkStore.shared.remove(id: bookmark.id)
        BrowserWindowController.all.forEach { $0.refreshChrome() }
        view.window?.performClose(nil)
    }

    @objc private func done() {
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != bookmark.title { BookmarkStore.shared.rename(id: bookmark.id, to: name) }
        view.window?.performClose(nil)
    }
}

// MARK: - Window and root view

final class BrowserWindow: NSWindow {
    /// Keys a page must not swallow: Chrome's tab shortcuts work even while a page has focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class RootView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}
