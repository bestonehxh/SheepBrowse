import AppKit
import WebKit

/// The row under the tabs: ‹ › ↻ in a glass capsule, the address field (Chrome's omnibox), and the
/// shield / downloads / menu capsule.
final class NavigationBarView: WindowDragView {
    /// The capsules sit right under the tab row (the same 6 pt gap as above the tabs) with 8 pt below.
    static let height: CGFloat = 42
    weak var controller: BrowserWindowController?

    let backButton: IconButton
    let forwardButton: IconButton
    let reloadButton: IconButton
    let homeButton: IconButton
    private let navGroup = GlassCapsule()
    let omnibox: OmniboxView
    private let toolsGroup = GlassCapsule()
    let shieldButton: IconButton
    let downloadsButton: DownloadsButton
    let menuButton: IconButton

    init(controller: BrowserWindowController) {
        self.controller = controller
        backButton = IconButton(symbol: "chevron.left", label: "Back", target: controller, action: #selector(BrowserWindowController.goBack(_:)))
        forwardButton = IconButton(symbol: "chevron.right", label: "Forward", target: controller, action: #selector(BrowserWindowController.goForward(_:)))
        reloadButton = IconButton(symbol: "arrow.clockwise", label: "Reload", target: controller, action: #selector(BrowserWindowController.reloadOrStop(_:)))
        homeButton = IconButton(symbol: "house", label: "Home", target: controller, action: #selector(BrowserWindowController.goHome(_:)))
        omnibox = OmniboxView(controller: controller)
        shieldButton = IconButton(symbol: "checkmark.shield", label: "Ad Blocker", target: controller, action: #selector(BrowserWindowController.showShieldMenu(_:)))
        downloadsButton = DownloadsButton(target: controller, action: #selector(BrowserWindowController.showDownloads(_:)))
        menuButton = IconButton(symbol: "ellipsis", label: "Menu", target: controller, action: #selector(BrowserWindowController.showMainMenu(_:)))
        super.init(frame: .zero)

        backButton.onLongPress = { [weak controller, weak backButton] in
            if let backButton { controller?.showHistoryMenu(back: true, from: backButton) }
        }
        backButton.onRightClick = { [weak controller, weak backButton] _ in
            if let backButton { controller?.showHistoryMenu(back: true, from: backButton) }
        }
        forwardButton.onLongPress = { [weak controller, weak forwardButton] in
            if let forwardButton { controller?.showHistoryMenu(back: false, from: forwardButton) }
        }
        forwardButton.onRightClick = { [weak controller, weak forwardButton] _ in
            if let forwardButton { controller?.showHistoryMenu(back: false, from: forwardButton) }
        }
        for button in [backButton, forwardButton] { button.pointSize = 14; button.weight = .semibold }
        reloadButton.pointSize = 13.5
        reloadButton.weight = .semibold
        shieldButton.pointSize = 14
        menuButton.pointSize = 14
        menuButton.weight = .bold

        homeButton.pointSize = 13.5
        homeButton.weight = .semibold
        for view in [backButton, forwardButton, reloadButton, homeButton] { navGroup.content.addSubview(view) }
        for view in [shieldButton, downloadsButton, menuButton] as [NSView] { toolsGroup.content.addSubview(view) }
        addSubview(navGroup)
        addSubview(omnibox)
        addSubview(toolsGroup)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h: CGFloat = 34
        let y = bounds.height - h
        homeButton.isHidden = !Settings.showHomeButton
        let navButtons = [backButton, forwardButton, reloadButton, homeButton].filter { !$0.isHidden }
        navGroup.frame = NSRect(x: 12, y: y, width: CGFloat(navButtons.count) * 30 + 8, height: h)
        for (index, button) in navButtons.enumerated() {
            button.frame = NSRect(x: 4 + CGFloat(index) * 30, y: 3, width: 30, height: 28)
        }
        let tools: [NSView] = [shieldButton, downloadsButton, menuButton].filter { !$0.isHidden }
        let toolsWidth = CGFloat(tools.count) * 30 + 8
        toolsGroup.frame = NSRect(x: bounds.width - 12 - toolsWidth, y: y, width: toolsWidth, height: h)
        for (index, view) in tools.enumerated() {
            view.frame = NSRect(x: 4 + CGFloat(index) * 30, y: 3, width: 30, height: 28)
        }
        omnibox.frame = NSRect(x: navGroup.frame.maxX + 10, y: y,
                               width: toolsGroup.frame.minX - 10 - navGroup.frame.maxX - 10, height: h)
    }

    func update(for tab: BrowserTab?) {
        backButton.isEnabled = tab?.canGoBack ?? false
        forwardButton.isEnabled = tab?.canGoForward ?? false
        let loading = tab?.isLoading ?? false
        reloadButton.symbol = loading ? "xmark" : "arrow.clockwise"
        reloadButton.setAccessibilityLabel(loading ? "Stop" : "Reload")
        reloadButton.isEnabled = tab?.url != nil
        let site = AddressInput.site(of: tab?.url?.host)
        let allowed = site.map { Settings.adBlockAllowedSites.contains($0) } ?? false
        shieldButton.symbol = !Settings.blockAds ? "shield.slash" : allowed ? "shield" : "checkmark.shield"
        shieldButton.contentTintColor = Settings.blockAds && !allowed ? .controlAccentColor : .secondaryLabelColor
        omnibox.update(for: tab)
        downloadsButton.refresh()
        needsLayout = true
    }
}

/// Shows a ring while downloads run; hidden until the first download, as in Chrome.
final class DownloadsButton: IconButton {
    private var observer: NSObjectProtocol?
    private let ring = CAShapeLayer()
    private let track = CAShapeLayer()

    init(target: AnyObject, action: Selector) {
        super.init(symbol: "arrow.down.circle", label: "Downloads", target: target, action: action)
        pointSize = 15
        for layer in [track, ring] {
            layer.fillColor = nil
            layer.lineWidth = 2
            layer.lineCap = .round
            self.layer?.addSublayer(layer)
        }
        observer = NotificationCenter.default.addObserver(forName: DownloadManager.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        let wasHidden = isHidden
        isHidden = DownloadManager.shared.items.isEmpty
        if wasHidden != isHidden { superview?.superview?.superview?.needsLayout = true; superview?.superview?.superview?.superview?.needsLayout = true }
        let fraction = DownloadManager.shared.overallFraction
        symbol = fraction == nil ? "arrow.down.circle" : "arrow.down"
        pointSize = fraction == nil ? 15 : 11
        let rect = NSRect(x: (bounds.width - 20) / 2, y: (bounds.height - 20) / 2, width: 20, height: 20)
        let path = CGPath(ellipseIn: rect, transform: nil)
        track.path = path
        track.strokeColor = NSColor.separatorColor.cgColor
        track.isHidden = fraction == nil
        // Starts at 12 o'clock and runs clockwise.
        let arc = CGMutablePath()
        arc.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: 10, startAngle: .pi / 2,
                   endAngle: .pi / 2 - 2 * .pi * CGFloat(max(0.02, fraction ?? 0)), clockwise: true)
        ring.path = arc
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.isHidden = fraction == nil
    }

    override func layout() {
        super.layout()
        refresh()
    }
}

// MARK: - The address field

/// Chrome's omnibox: shows the page's address (host in full colour, the rest dimmed); typing searches
/// Google with live suggestions, matches history, favorites and open tabs, and completes a typed host
/// inline. Return opens the selected row, ⌥Return opens it in a new tab, Esc puts the address back.
final class OmniboxView: GlassCapsule, NSTextFieldDelegate {
    private weak var controller: BrowserWindowController?
    let field = AddressField()
    let siteButton: IconButton
    private let zoomButton = NSButton(title: "", target: nil, action: nil)
    let starButton: IconButton
    /// Red while the page uses the camera or microphone; a click shows stop/mute.
    let captureButton = IconButton(symbol: "video.fill", label: "Camera and Microphone", target: nil, action: nil)
    private let progressLayer = CALayer()
    private let suggestions = SuggestionPanel()

    private var currentTab: BrowserTab?
    /// What the user typed, without the inline completion.
    private var typed = ""
    private var inlineCompletionURL: URL?
    private var suppressCompletion = false
    private var rows: [Row] = []
    private var suggestTask: URLSessionDataTask?
    private var googleSuggestions: [String] = []

    enum Row {
        case search(String)
        case url(URL)
        case history(HistoryEntry)
        case favorite(Bookmark)
        case openTab(BrowserTab)
    }

    init(controller: BrowserWindowController) {
        self.controller = controller
        siteButton = IconButton(symbol: "magnifyingglass", label: "Site Information", target: controller,
                                action: #selector(BrowserWindowController.showSiteInfo(_:)))
        starButton = IconButton(symbol: "star", label: "Add to Favorites", target: controller,
                                action: #selector(BrowserWindowController.toggleFavorite(_:)))
        super.init(radius: nil, interactive: false)

        progressLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        progressLayer.cornerRadius = 0
        content.wantsLayer = true
        content.layer?.addSublayer(progressLayer)

        siteButton.pointSize = 11.5
        siteButton.weight = .semibold
        siteButton.contentTintColor = .secondaryLabelColor
        starButton.pointSize = 13.5

        field.delegate = self
        field.omnibox = self
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13.5)
        field.placeholderString = "Search \(Settings.searchEngine.name) or type a URL"
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true

        zoomButton.isBordered = false
        zoomButton.font = .systemFont(ofSize: 11, weight: .medium)
        zoomButton.contentTintColor = .secondaryLabelColor
        zoomButton.target = controller
        zoomButton.action = #selector(BrowserWindowController.actualSize(_:))
        zoomButton.wantsLayer = true
        zoomButton.layer?.cornerRadius = 9
        zoomButton.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor

        captureButton.pointSize = 12
        captureButton.contentTintColor = .systemRed
        captureButton.target = self
        captureButton.action = #selector(showCaptureMenu)
        for view in [siteButton, field, zoomButton, captureButton, starButton] as [NSView] { content.addSubview(view) }

        suggestions.onPick = { [weak self] index in self?.commit(row: index, newTab: false) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        siteButton.frame = NSRect(x: 4, y: (h - 26) / 2, width: 28, height: 26)
        var right = bounds.width - 4
        starButton.isHidden = currentTab?.url == nil || currentTab?.internalPage != nil || field.isEditing
        if !starButton.isHidden {
            starButton.frame = NSRect(x: right - 28, y: (h - 26) / 2, width: 28, height: 26)
            right -= 30
        }
        captureButton.isHidden = !(currentTab?.isCapturing ?? false) || field.isEditing
        if !captureButton.isHidden {
            captureButton.frame = NSRect(x: right - 28, y: (h - 26) / 2, width: 28, height: 26)
            right -= 30
        }
        if !zoomButton.isHidden {
            let width = zoomButton.intrinsicContentSize.width + 12
            zoomButton.frame = NSRect(x: right - width, y: (h - 18) / 2, width: width, height: 18)
            right -= width + 6
        }
        field.frame = NSRect(x: 34, y: (h - 18) / 2, width: max(10, right - 36), height: 18)
        updateProgress(animated: false)
    }

    func update(for tab: BrowserTab?) {
        currentTab = tab
        field.placeholderString = "Search \(Settings.searchEngine.name) or type a URL"
        if !field.isEditing { showAddress() }
        let zoom = tab?.webView?.pageZoom ?? 1
        zoomButton.isHidden = abs(zoom - 1) < 0.001 || field.isEditing
        zoomButton.title = "\(Int(round(zoom * 100)))%"
        captureButton.symbol = tab?.cameraState != WKMediaCaptureState.none ? "video.fill" : "mic.fill"
        let favorite = BookmarkStore.shared.bookmark(for: tab?.url) != nil
        starButton.symbol = favorite ? "star.fill" : "star"
        starButton.contentTintColor = favorite ? .systemYellow : .secondaryLabelColor
        starButton.setAccessibilityLabel(favorite ? "Edit Favorite" : "Add to Favorites")
        updateSiteIcon()
        updateProgress(animated: true)
        needsLayout = true
    }

    @objc private func showCaptureMenu() {
        guard let tab = currentTab else { return }
        let menu = NSMenu()
        if tab.cameraState != .none {
            menu.addItem(ClosureMenuItem(title: tab.cameraState == .active ? "Turn Off Camera" : "Turn Camera Back On") {
                tab.setCapture(camera: tab.cameraState == .active ? .muted : .active)
            })
        }
        if tab.microphoneState != .none {
            menu.addItem(ClosureMenuItem(title: tab.microphoneState == .active ? "Mute Microphone" : "Unmute Microphone") {
                tab.setCapture(microphone: tab.microphoneState == .active ? .muted : .active)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Stop Sharing with This Page") { tab.setCapture(camera: WKMediaCaptureState.none, microphone: WKMediaCaptureState.none) })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: captureButton.bounds.height + 4), in: captureButton)
    }

    private func updateSiteIcon() {
        if !field.isEditing, let page = currentTab?.internalPage {
            siteButton.symbol = page.symbol
            siteButton.contentTintColor = .controlAccentColor
            return
        }
        guard !field.isEditing, let url = currentTab?.url, currentTab?.isNewTabPage == false else {
            siteButton.symbol = "magnifyingglass"
            siteButton.contentTintColor = .secondaryLabelColor
            return
        }
        switch SiteSecurity.state(for: currentTab) {
        case .secure: siteButton.symbol = "lock.fill"; siteButton.contentTintColor = .secondaryLabelColor
        case .trustedByUser: siteButton.symbol = "lock.badge.checkmark.fill"; siteButton.contentTintColor = .systemOrange
        case .mixed: siteButton.symbol = "lock.trianglebadge.exclamationmark.fill"; siteButton.contentTintColor = .systemOrange
        case .insecure: siteButton.symbol = url.scheme == "http" ? "exclamationmark.triangle.fill" : "info.circle"
            siteButton.contentTintColor = url.scheme == "http" ? .systemOrange : .secondaryLabelColor
        }
    }

    private func updateProgress(animated: Bool) {
        let loading = currentTab?.isLoading == true && !(currentTab?.isNewTabPage ?? true)
        let fraction = loading ? max(0.08, currentTab?.progress ?? 0) : (progressLayer.opacity > 0 ? 1 : 0)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.25)
        progressLayer.frame = NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        progressLayer.opacity = loading ? 1 : 0
        CATransaction.commit()
    }

    /// The page's address, Chrome-style: no https://, the host in full colour, the rest dimmed.
    func showAddress() {
        guard let url = currentTab?.url, currentTab?.isNewTabPage == false else {
            field.stringValue = ""
            return
        }
        let display = AddressInput.display(url)
        let attributed = NSMutableAttributedString(string: display, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 13.5),
        ])
        var host = url.host ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if let range = display.range(of: host) {
            attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(range, in: display))
        }
        field.attributedStringValue = attributed
    }

    // MARK: Editing

    func beginEditing(selectAll: Bool = true) {
        window?.makeFirstResponder(field)
    }

    fileprivate func fieldDidBeginEditing() {
        let full = currentTab?.isNewTabPage == false ? (currentTab?.url?.absoluteString ?? "") : ""
        field.stringValue = full == "about:blank" ? "" : full
        typed = field.stringValue
        zoomButton.isHidden = true
        updateSiteIcon()
        needsLayout = true
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        suggestions.hide()
        suggestTask?.cancel()
        showAddress()
        update(for: currentTab)
    }

    func controlTextDidChange(_ obj: Notification) {
        // While an input method composes (Japanese, Chinese, Thai with some layouts) the text is not final:
        // completing it would replace what is being composed.
        guard let editor = field.currentEditor() as? NSTextView, !editor.hasMarkedText() else { return }
        let text = editor.string
        // Text before the selection is what was typed; a selection at the end is our completion.
        let selected = editor.selectedRange()
        typed = selected.length > 0 && NSMaxRange(selected) == (text as NSString).length
            ? (text as NSString).substring(to: selected.location) : text
        inlineCompletionURL = nil
        fetchGoogleSuggestions(for: typed)
        refreshSuggestions()
        if !suppressCompletion { completeInline(editor) }
        suppressCompletion = false
    }

    /// Fills in the rest of a host the user has visited ("git" → "github.com") as selected text.
    private func completeInline(_ editor: NSTextView) {
        let needle = typed.lowercased()
        guard !needle.isEmpty, !needle.contains(" "),
              let match = HistoryStore.shared.suggestions(for: needle, limit: 6).first(where: {
                  AddressInput.display(URL(string: $0.url)).lowercased().hasPrefix(needle)
              }),
              let url = URL(string: match.url) else { return }
        // Complete to the host when the typed text is still inside it (Chrome completes sites first).
        var target = AddressInput.display(url)
        var targetURL = url
        if let host = url.host.map({ $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }), host.lowercased().hasPrefix(needle),
           let root = URL(string: "\(url.scheme ?? "https")://\(url.host ?? host)/") {
            target = host
            targetURL = root
        }
        guard target.lowercased().hasPrefix(needle), target.count > typed.count else { return }
        let completion = String(target.dropFirst(typed.count))
        editor.string = typed + completion
        editor.setSelectedRange(NSRange(location: (typed as NSString).length, length: (completion as NSString).length))
        inlineCompletionURL = targetURL
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if suggestions.isShowing { suggestions.moveSelection(1); previewSelection() }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if suggestions.isShowing { suggestions.moveSelection(-1); previewSelection() }
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            let newTab = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
            if suggestions.isShowing, let index = suggestions.selectedIndex, index > 0 || inlineCompletionURL == nil {
                commit(row: index, newTab: newTab)
            } else if let url = inlineCompletionURL {
                go(to: url, typed: true, newTab: newTab)
            } else if let url = AddressInput.url(for: textView.string) {
                go(to: url, typed: true, newTab: newTab, upgraded: !textView.string.contains("://"))
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            suggestTask?.cancel()
            if suggestions.isShowing {
                suggestions.hide()
            } else {
                window?.makeFirstResponder(controller?.currentContentView)
            }
            return true
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)):
            suppressCompletion = true
            return false
        default:
            return false
        }
    }

    /// While moving through rows, the field shows the row (as Chrome).
    private func previewSelection() {
        guard let index = suggestions.selectedIndex, index < rows.count else { return }
        let text: String
        switch rows[index] {
        case .search(let query): text = query
        case .url(let url): text = url.absoluteString
        case .history(let entry): text = entry.url
        case .favorite(let bookmark): text = bookmark.url ?? ""
        case .openTab(let tab): text = tab.url?.absoluteString ?? ""
        }
        field.stringValue = text
        inlineCompletionURL = nil
    }

    private func refreshSuggestions() {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let window else {
            rows = []
            suggestions.hide()
            return
        }
        var list: [Row] = []
        // 1. What was typed: a URL to open, or a Google search.
        if let url = AddressInput.url(for: text), url != AddressInput.searchURL(for: text) {
            list.append(.url(url))
        } else {
            list.append(.search(text))
        }
        // 2. Open tabs (switch to them), favorites, history.
        let needle = text.lowercased()
        let tabs = BrowserWindowController.all.flatMap(\.tabs).filter { tab in
            tab !== currentTab && !tab.isNewTabPage &&
                (tab.title.lowercased().contains(needle) || (tab.url?.absoluteString.lowercased().contains(needle) ?? false))
        }
        list += tabs.prefix(2).map(Row.openTab)
        let favorites = BookmarkStore.shared.allPages.filter {
            $0.title.lowercased().contains(needle) || ($0.url?.lowercased().contains(needle) ?? false)
        }
        list += favorites.prefix(2).map(Row.favorite)
        let shown = Set(favorites.prefix(2).compactMap(\.url))
        list += HistoryStore.shared.suggestions(for: text, limit: 6).filter { !shown.contains($0.url) }.prefix(3).map(Row.history)
        // 3. Google's suggestions.
        // Only Google's answers for what is typed now (an older answer may still be in hand).
        list += googleSuggestions.filter { $0.lowercased() != needle && $0.lowercased().hasPrefix(needle) }.prefix(max(0, 9 - list.count)).map(Row.search)
        rows = Array(list.prefix(9))

        let items = rows.map(item(for:))
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        suggestions.show(items, below: anchor, width: bounds.width, parent: window, select: 0)
    }

    private func item(for row: Row) -> SuggestionItem {
        switch row {
        case .search(let query):
            return SuggestionItem(symbol: "magnifyingglass", title: query, detail: query == typed.trimmingCharacters(in: .whitespaces) ? "\(Settings.searchEngine.name) Search" : nil)
        case .url(let url):
            return SuggestionItem(symbol: "globe", image: FaviconCache.shared.image(for: url.host), title: AddressInput.display(url), detail: nil)
        case .history(let entry):
            let url = URL(string: entry.url)
            return SuggestionItem(symbol: "clock", image: FaviconCache.shared.image(for: url?.host),
                                  title: entry.title.isEmpty ? AddressInput.display(url) : entry.title,
                                  detail: AddressInput.display(url))
        case .favorite(let bookmark):
            let url = bookmark.url.flatMap(URL.init(string:))
            return SuggestionItem(symbol: "star", image: FaviconCache.shared.image(for: url?.host), title: bookmark.title,
                                  detail: AddressInput.display(url), badge: "Favorite")
        case .openTab(let tab):
            return SuggestionItem(symbol: "square.on.square", image: tab.favicon, title: tab.title,
                                  detail: AddressInput.display(tab.url), badge: "Switch to Tab")
        }
    }

    private func commit(row index: Int, newTab: Bool) {
        guard index < rows.count else { return }
        switch rows[index] {
        case .search(let query): if let url = AddressInput.searchURL(for: query) { go(to: url, typed: false, newTab: newTab) }
        case .url(let url): go(to: url, typed: true, newTab: newTab, upgraded: !typed.contains("://"))
        case .history(let entry): if let url = URL(string: entry.url) { go(to: url, typed: true, newTab: newTab) }
        case .favorite(let bookmark): if let url = bookmark.url.flatMap(URL.init(string:)) { go(to: url, typed: true, newTab: newTab) }
        case .openTab(let tab):
            suggestions.hide()
            BrowserWindowController.reveal(tab)
            return
        }
    }

    /// `upgraded`: the user typed no scheme and got https:// (only then may a refused connection retry http).
    private func go(to url: URL, typed: Bool, newTab: Bool, upgraded: Bool = false) {
        suggestions.hide()
        suggestTask?.cancel()
        controller?.open(url, typed: typed, disposition: newTab ? .newTab : .current, upgraded: upgraded)
        window?.makeFirstResponder(controller?.currentContentView)
    }

    private func fetchGoogleSuggestions(for text: String) {
        suggestTask?.cancel()
        let query = text.trimmingCharacters(in: .whitespaces)
        // Suggestions come from Google: only when Google is the search engine (choosing another one means
        // the typing should not go to Google).
        guard Settings.searchSuggestions, Settings.searchEngine == .google, !query.isEmpty, !(controller?.isPrivate ?? false),
              !AddressInput.isHostShaped(query) || query.count < 4,
              var components = URLComponents(string: "https://suggestqueries.google.com/complete/search") else {
            googleSuggestions = []
            return
        }
        components.queryItems = [.init(name: "client", value: "firefox"), .init(name: "q", value: query),
                                 .init(name: "hl", value: Locale.preferredLanguages.first ?? "en")]
        guard let url = components.url else { return }
        suggestTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let list = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] }
            let words = (list?.count ?? 0) > 1 ? (list?[1] as? [String] ?? []) : []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.field.isEditing, self.typed.trimmingCharacters(in: .whitespaces) == query else { return }
                    self.googleSuggestions = words
                    // Not while the user is on a row (it would change under the selection), nor after Esc.
                    guard self.suggestions.isShowing, (self.suggestions.selectedIndex ?? 0) == 0 else { return }
                    self.refreshSuggestions()
                }
            }
        }
        suggestTask?.resume()
    }
}

/// The address text field; tells the omnibox when editing starts (select-all on click, as Chrome).
final class AddressField: NSTextField {
    weak var omnibox: OmniboxView?
    private(set) var isEditing = false

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became && !isEditing {
            isEditing = true
            omnibox?.fieldDidBeginEditing()
        }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        isEditing = false
        super.textDidEndEditing(notification)
    }

    /// The first click selects the whole address (Chrome); later clicks place the caret as usual (they go
    /// to the field editor, not here).
    override func mouseDown(with event: NSEvent) {
        guard !isEditing else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }

    override var mouseDownCanMoveWindow: Bool { false }
}
