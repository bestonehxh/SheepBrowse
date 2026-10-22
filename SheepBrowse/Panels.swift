import AppKit
import WebKit

// MARK: - New tab page (native: no web process until something is opened)

final class NewTabPageView: NSView {
    var onOpen: ((URL, OpenDisposition) -> Void)?
    private let logo = NSTextField(labelWithString: "")
    private let grid = NSStackView()
    private var observer: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let attributed = NSMutableAttributedString(string: "Sheep", attributes: [
            .font: NSFont.systemFont(ofSize: 46, weight: .bold), .foregroundColor: NSColor.labelColor, .kern: -1.5,
        ])
        attributed.append(NSAttributedString(string: "Browse", attributes: [
            .font: NSFont.systemFont(ofSize: 46, weight: .bold), .foregroundColor: NSColor.controlAccentColor, .kern: -1.5,
        ]))
        logo.attributedStringValue = attributed
        addSubview(logo)
        grid.orientation = .vertical
        grid.spacing = 18
        addSubview(grid)
        reload()
        observer = NotificationCenter.default.addObserver(forName: HistoryStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.window == nil { self?.needsReload = true } }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private var needsReload = false

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow != nil, needsReload { reload() }
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    func reload() {
        needsReload = false
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Favorites first, then the most visited sites, eight tiles in two rows.
        var tiles: [(String, URL)] = BookmarkStore.shared.allPages.prefix(4).compactMap { bookmark in
            bookmark.url.flatMap(URL.init(string:)).map { (bookmark.title, $0) }
        }
        let used = Set(tiles.map { $0.1.host })
        for entry in HistoryStore.shared.topSites(12) where tiles.count < 8 {
            guard let url = URL(string: entry.url), !used.contains(url.host) else { continue }
            let name = Self.tileName(for: url) ?? entry.title
            tiles.append((name, url))
        }
        for row in stride(from: 0, to: tiles.count, by: 4) {
            let line = NSStackView(views: tiles[row..<min(row + 4, tiles.count)].map { SiteTile(title: $0.0, url: $0.1, page: self) })
            line.spacing = 18
            grid.addArrangedSubview(line)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        logo.sizeToFit()
        let gridSize = grid.fittingSize
        // The block's middle sits a little above the middle of the page (non-flipped: y counts up from the bottom).
        let total = logo.frame.height + 34 + gridSize.height
        let top = min(bounds.height - 40, bounds.height * 0.56 + total / 2)
        logo.frame.origin = NSPoint(x: (bounds.width - logo.frame.width) / 2, y: top - logo.frame.height)
        grid.frame = NSRect(x: (bounds.width - gridSize.width) / 2, y: logo.frame.minY - 34 - gridSize.height,
                            width: gridSize.width, height: gridSize.height)
    }

    fileprivate func open(_ url: URL, disposition: OpenDisposition) { onOpen?(url, disposition) }

    /// "mail.google.com" → "Mail", "www.google.com" → "Google", "github.com" → "Github": the part that tells
    /// sites of one company apart.
    static func tileName(for url: URL) -> String? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if AddressInput.isIPv4(host) { return host }
        let site = AddressInput.site(of: host) ?? host
        let word = host == site ? site.split(separator: ".").first.map(String.init) : host.split(separator: ".").first.map(String.init)
        return word.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }
}

private final class SiteTile: NSView {
    private let url: URL
    private weak var page: NewTabPageView?
    private let iconBox = GlassCapsule(radius: 16, interactive: true)

    init(title: String, url: URL, page: NewTabPageView) {
        self.url = url
        self.page = page
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: FaviconCache.shared.image(for: url.host) ?? NSImage.monogram(for: url.host))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBox.content.addSubview(icon)
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconBox)
        addSubview(label)
        toolTip = url.absoluteString
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 96), heightAnchor.constraint(equalToConstant: 92),
            iconBox.topAnchor.constraint(equalTo: topAnchor),
            iconBox.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconBox.widthAnchor.constraint(equalToConstant: 60), iconBox.heightAnchor.constraint(equalToConstant: 60),
            icon.centerXAnchor.constraint(equalTo: iconBox.content.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBox.content.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28),
            label.topAnchor.constraint(equalTo: iconBox.bottomAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor), label.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        page?.open(url, disposition: event.modifierFlags.contains(.command) ? .backgroundTab : .current)
    }

    override func otherMouseUp(with event: NSEvent) { page?.open(url, disposition: .backgroundTab) }
}

// MARK: - Find in page

final class FindBarView: GlassCapsule, NSTextFieldDelegate {
    private let searchRow = SearchRow(placeholder: "Find on page", size: 13)
    var field: PlainSearchField { searchRow.field }
    private let status = NSTextField(labelWithString: "")
    var onFind: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?

    init() {
        super.init(radius: nil, interactive: false)
        field.delegate = self
        searchRow.onClear = { [weak self] in self?.onFind?("", false) }
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let previous = IconButton(symbol: "chevron.up", label: "Previous", target: self, action: #selector(findPrevious))
        let next = IconButton(symbol: "chevron.down", label: "Next", target: self, action: #selector(findNext))
        let close = IconButton(symbol: "xmark", label: "Close", target: self, action: #selector(closeBar))
        for button in [previous, next, close] { button.pointSize = 11; button.weight = .semibold }
        let stack = NSStackView(views: [searchRow, status, previous, next, close])
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            searchRow.widthAnchor.constraint(equalToConstant: 190),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func showResult(found: Bool) {
        status.stringValue = field.stringValue.isEmpty || found ? "" : "Not found"
    }

    func controlTextDidChange(_ obj: Notification) { onFind?(field.stringValue, false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { closeBar(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            onFind?(field.stringValue, NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
            return true
        }
        return false
    }

    @objc func findNext() { onFind?(field.stringValue, false) }
    @objc func findPrevious() { onFind?(field.stringValue, true) }
    @objc private func closeBar() { onClose?() }
}

// MARK: - Search tabs (⌘⇧A, the ⌄ at the left of the tabs)

/// Chrome's tab search: a search field over "Open Tabs" (every window) and "Recently Closed".
final class TabSearchController: NSObject, NSTextFieldDelegate {
    static let shared = TabSearchController()
    private let panel = SuggestionPanel()
    private let searchRow = SearchRow(placeholder: "Search Tabs", size: 14)
    private var targets: [Target?] = []
    private weak var parentWindow: NSWindow?
    private var anchor: NSRect = .zero

    private enum Target {
        case tab(BrowserTab)
        case closed(UUID)
    }

    override init() {
        super.init()
        panel.keyable = true
        searchRow.field.delegate = self
        searchRow.onClear = { [weak self] in self?.refresh() }
        let shortcut = NSTextField(labelWithString: "⇧⌘A")
        shortcut.font = .systemFont(ofSize: 11.5, weight: .medium)
        shortcut.textColor = .tertiaryLabelColor
        let header = NSStackView(views: [searchRow, shortcut])
        header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        header.spacing = 8
        panel.header = (header, 40)
        panel.onPick = { [weak self] index in self?.pick(index) }
    }

    func show(below button: NSView, in window: NSWindow) {
        parentWindow = window
        anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        searchRow.field.stringValue = ""
        searchRow.refresh()
        refresh()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchRow.field)
    }

    private func refresh() {
        guard let window = parentWindow else { return }
        let needle = searchRow.field.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        func matches(_ title: String, _ url: URL?) -> Bool {
            needle.isEmpty || title.lowercased().contains(needle) || (url?.absoluteString.lowercased().contains(needle) ?? false)
        }
        let ago = RelativeDateTimeFormatter()
        ago.unitsStyle = .full
        var items: [SuggestionItem] = []
        targets = []

        let open = BrowserWindowController.all.flatMap(\.tabs).filter { matches($0.title, $0.url) }
        if !open.isEmpty {
            items.append(.section("Open Tabs"))
            targets.append(nil)
        }
        for tab in open.prefix(12) {
            let place = tab.internalPage?.url.absoluteString ?? tab.url?.host
            let when = tab === BrowserWindowController.frontmost?.selectedTab ? "now" : ago.localizedString(for: tab.lastActive, relativeTo: Date())
            let image = tab.isNewTabPage
                ? NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: nil)
                : tab.favicon ?? NSImage.monogram(for: tab.url?.host)
            items.append(SuggestionItem(image: image, title: tab.title, badge: tab.isAsleep ? "Sleeping" : nil,
                                        subtitle: place.map { "\($0) · \(when)" } ?? when, tiled: true))
            targets.append(.tab(tab))
        }
        let closed = RecentlyClosed.shared.items.reversed().filter { matches($0.title, $0.url) }
        if !closed.isEmpty {
            items.append(.section("Recently Closed"))
            targets.append(nil)
        }
        for item in closed.prefix(10) {
            let page = InternalPage(url: item.url)
            let place = item.window != nil ? "Window" : page?.url.absoluteString ?? (item.url?.host ?? "")
            let image = item.window != nil
                ? NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
                : page?.icon ?? FaviconCache.shared.image(for: item.url?.host) ?? NSImage.monogram(for: item.url?.host)
            items.append(SuggestionItem(image: image, title: item.title,
                                        subtitle: "\(place) · \(ago.localizedString(for: item.date, relativeTo: Date()))", tiled: true))
            targets.append(.closed(item.id))
        }
        panel.show(items, below: anchor, width: 400, parent: window, select: 0)
    }

    private func pick(_ index: Int) {
        guard index < targets.count, let target = targets[index] else { return }
        panel.hide()
        switch target {
        case .tab(let tab): BrowserWindowController.reveal(tab)
        case .closed(let id): RecentlyClosed.shared.reopen(id)
        }
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): panel.moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): panel.moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            if let index = panel.selectedIndex { pick(index) }
            return true
        case #selector(NSResponder.cancelOperation(_:)): panel.hide(); return true
        default: return false
        }
    }
}
