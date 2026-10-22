import AppKit
import UniformTypeIdentifiers

/// The app's own pages (sheep://downloads, sheep://favorites, sheep://history), drawn natively in a tab
/// like Chrome's chrome://downloads: a title and a search box on top, cards grouped by day below.
enum InternalPage: String, CaseIterable {
    case downloads, favorites, history

    var url: URL { URL(string: "sheep://\(rawValue)")! }

    var title: String {
        switch self {
        case .downloads: "Downloads"
        case .favorites: "Favorites"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .downloads: "arrow.down.circle.fill"
        case .favorites: "star.fill"
        case .history: "clock.fill"
        }
    }

    init?(url: URL?) {
        guard let url, url.scheme == "sheep", let host = url.host, let page = InternalPage(rawValue: host) else { return nil }
        self = page
    }

    var icon: NSImage {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium).applying(.init(paletteColors: [.controlAccentColor])))!
        return image
    }

    @MainActor
    func makeView(open: @escaping (URL, OpenDisposition) -> Void) -> ListPageView {
        switch self {
        case .downloads: DownloadsPageView(open: open)
        case .favorites: FavoritesPageView(open: open)
        case .history: HistoryPageView(open: open)
        }
    }
}

// MARK: - The shared page

struct PageAction {
    var symbol: String
    var label: String
    var handler: () -> Void
}

struct PageCard {
    var image: NSImage?
    var tiled = true
    var title: String
    var status: String?
    var detail: String?
    /// Crossed out (a deleted or cancelled download).
    var struck = false
    var actions: [PageAction] = []
    var onOpen: (() -> Void)?
    /// What dragging the card carries (nil = not draggable).
    var dragItem: (() -> NSPasteboardItem)?
    /// A drop ONTO the card (a folder); true = taken.
    var onDrop: ((NSPasteboard) -> Bool)?
}

struct PageSection {
    var title: String
    var cards: [PageCard]
}

class ListPageView: NSView, NSTextFieldDelegate {
    let open: (URL, OpenDisposition) -> Void
    private let page: InternalPage
    private let titleLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let searchBox = GlassCapsule(radius: 18, interactive: false)
    let searchRow: SearchRow
    var search: PlainSearchField { searchRow.field }
    private let headerButtons = NSStackView()
    private let scroll = NSScrollView()
    private let document = DropDocumentView()
    private var observers: [NSObjectProtocol] = []
    private var reloadScheduled = false
    /// Above the sections (the favorites breadcrumb).
    var breadcrumb: [(String, () -> Void)] = []
    /// Drops on a breadcrumb step (moving a favorite up), by step index.
    var onBreadcrumbDrop: ((Int, NSPasteboard) -> Bool)?
    /// A drop between cards: the index (among the cards, top to bottom) it lands before. nil = no reordering.
    var onReorderDrop: ((Int, NSPasteboard) -> Bool)? {
        didSet { document.onDrop = onReorderDrop }
    }

    init(page: InternalPage, open: @escaping (URL, OpenDisposition) -> Void) {
        self.page = page
        self.open = open
        searchRow = SearchRow(placeholder: "Search \(page.title.lowercased())")
        super.init(frame: .zero)
        wantsLayer = true

        iconView.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .regular))
        iconView.contentTintColor = .controlAccentColor
        titleLabel.stringValue = page.title
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        search.delegate = self
        searchRow.onClear = { [weak self] in self?.reload() }
        searchBox.content.addSubview(searchRow)
        NSLayoutConstraint.activate([
            searchRow.leadingAnchor.constraint(equalTo: searchBox.content.leadingAnchor, constant: 14),
            searchRow.trailingAnchor.constraint(equalTo: searchBox.content.trailingAnchor, constant: -8),
            searchRow.centerYAnchor.constraint(equalTo: searchBox.content.centerYAnchor),
        ])
        headerButtons.spacing = 8
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        for view in [iconView, titleLabel, searchBox, headerButtons, scroll] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }

    /// Rebuilds when `name` is posted (at most twice a second: downloads report progress often).
    func observe(_ name: Notification.Name) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        })
    }

    func scheduleReload() {
        // A page not on screen rebuilds when it comes back (viewWillMove(toWindow:)).
        guard !reloadScheduled, window != nil else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.reloadScheduled = false
            self?.reload()
        }
    }

    func setHeaderButtons(_ buttons: [(String, () -> Void)]) {
        headerButtons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (title, handler) in buttons {
            let button = ClosureButton(title: title, handler: handler)
            button.bezelStyle = .glass
            headerButtons.addArrangedSubview(button)
        }
    }

    /// Subclasses return their sections for the search text.
    func sections(matching query: String) -> [PageSection] { [] }
    var emptyText: String { "Nothing here yet" }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow != nil { reload() }
    }

    func reload() {
        document.subviews.forEach { $0.removeFromSuperview() }
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let sections = sections(matching: query)
        let width = columnWidth
        var y: CGFloat = 8
        if !breadcrumb.isEmpty && query.isEmpty {
            let crumbs = NSStackView()
            crumbs.spacing = 4
            for (index, crumb) in breadcrumb.enumerated() {
                if index > 0 {
                    let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!)
                    chevron.contentTintColor = .tertiaryLabelColor
                    crumbs.addArrangedSubview(chevron)
                }
                let button = DropClosureButton(title: crumb.0, handler: crumb.1)
                if let drop = onBreadcrumbDrop { button.onDrop = { drop(index, $0) } }
                button.isBordered = false
                button.font = .systemFont(ofSize: 13, weight: index == breadcrumb.count - 1 ? .semibold : .regular)
                button.contentTintColor = index == breadcrumb.count - 1 ? .labelColor : .secondaryLabelColor
                crumbs.addArrangedSubview(button)
            }
            crumbs.frame = NSRect(x: 0, y: y, width: width, height: 24)
            document.addSubview(crumbs)
            y += 34
        }
        if sections.allSatisfy({ $0.cards.isEmpty }) {
            let empty = NSTextField(labelWithString: query.isEmpty ? emptyText : "No results for “\(query)”")
            empty.font = .systemFont(ofSize: 15, weight: .medium)
            empty.textColor = .tertiaryLabelColor
            empty.sizeToFit()
            empty.frame.origin = NSPoint(x: (width - empty.frame.width) / 2, y: y + 60)
            document.addSubview(empty)
            y += 140
        }
        for section in sections where !section.cards.isEmpty {
            if !section.title.isEmpty {
                let header = NSTextField(labelWithString: section.title)
                header.font = .systemFont(ofSize: 14, weight: .semibold)
                header.frame = NSRect(x: 2, y: y + 10, width: width, height: 20)
                document.addSubview(header)
                y += 40
            }
            for card in section.cards {
                let view = PageCardView(card: card)
                view.frame = NSRect(x: 0, y: y, width: width, height: 60)
                document.addSubview(view)
                y += 68
            }
            y += 14
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: y + 20)
        document.cardFrames = query.isEmpty ? document.subviews.compactMap { ($0 as? PageCardView)?.frame } : []
        document.acceptsDrops = query.isEmpty
        needsLayout = true
    }

    private var columnWidth: CGFloat { min(860, max(320, bounds.width - 48)) }

    override func layout() {
        super.layout()
        let top = bounds.height
        let width = columnWidth
        let x = (bounds.width - width) / 2
        iconView.frame = NSRect(x: x, y: top - 24 - 34, width: 34, height: 34)
        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: iconView.frame.maxX + 10, y: iconView.frame.midY - titleLabel.frame.height / 2)
        let buttonsWidth = headerButtons.fittingSize.width
        let searchX = max(titleLabel.frame.maxX + 24, x + width * 0.4)
        var contentTop = iconView.frame.minY - 14
        if x + width - buttonsWidth - 12 - searchX >= 240 {
            // One row: title · search · buttons.
            headerButtons.frame = NSRect(x: x + width - buttonsWidth, y: iconView.frame.midY - 15, width: buttonsWidth, height: 30)
            searchBox.frame = NSRect(x: searchX, y: iconView.frame.midY - 18, width: headerButtons.frame.minX - 12 - searchX, height: 36)
        } else {
            // Not enough room: the buttons get their own row under the title, the search box the rest of the first.
            searchBox.frame = NSRect(x: searchX, y: iconView.frame.midY - 18, width: x + width - searchX, height: 36)
            headerButtons.frame = NSRect(x: x, y: iconView.frame.minY - 14 - 30, width: buttonsWidth, height: 30)
            contentTop = headerButtons.frame.minY - 12
        }
        scroll.frame = NSRect(x: x - 4, y: 0, width: width + 8, height: contentTop)
        if abs(document.frame.width - width) > 1 { reload() }
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    /// "Today", "Yesterday", or the date.
    static func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .complete, time: .omitted)
    }

    static func grouped<T>(_ items: [T], date: (T) -> Date, card: (T) -> PageCard) -> [PageSection] {
        var sections: [PageSection] = []
        for item in items {
            let title = dayTitle(date(item))
            if sections.last?.title != title { sections.append(PageSection(title: title, cards: [])) }
            sections[sections.count - 1].cards.append(card(item))
        }
        return sections
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The page's card column; takes drops BETWEEN cards (reordering) with a line where they would land.
final class DropDocumentView: NSView {
    override var isFlipped: Bool { true }
    var onDrop: ((Int, NSPasteboard) -> Bool)? {
        didSet { onDrop == nil ? unregisterDraggedTypes() : registerForDraggedTypes(FavoriteDrag.acceptedTypes) }
    }
    var cardFrames: [NSRect] = []
    /// Off while a search filters the list (an index there means nothing); on for an empty folder too.
    var acceptsDrops = false
    private let line = NSBox()

    override init(frame: NSRect) {
        super.init(frame: frame)
        line.boxType = .custom
        line.fillColor = .controlAccentColor
        line.borderWidth = 0
        line.cornerRadius = 1.5
        line.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private func index(at point: NSPoint) -> Int { cardFrames.filter { $0.midY < point.y }.count }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onDrop != nil, acceptsDrops else { return [] }
        let at = index(at: convert(sender.draggingLocation, from: nil))
        let y = at < cardFrames.count ? cardFrames[at].minY - 4 : (cardFrames.last?.maxY ?? 0) + 4
        if line.superview == nil { addSubview(line) }
        line.frame = NSRect(x: 8, y: y - 1.5, width: bounds.width - 16, height: 3)
        line.isHidden = false
        return FavoriteDrag.read(sender.draggingPasteboard).id != nil ? .move : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { line.isHidden = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        line.isHidden = true
        return onDrop?(index(at: convert(sender.draggingLocation, from: nil)), sender.draggingPasteboard) ?? false
    }
}

/// A breadcrumb step that takes drops (move a favorite up into that folder).
final class DropClosureButton: NSButton {
    private var handler: () -> Void = {}
    var onDrop: ((NSPasteboard) -> Bool)? {
        didSet { onDrop == nil ? unregisterDraggedTypes() : registerForDraggedTypes(FavoriteDrag.acceptedTypes) }
    }

    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.handler = handler
        target = self
        action = #selector(run)
    }

    @objc private func run() { handler() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
        layer?.cornerRadius = 6
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { layer?.backgroundColor = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.backgroundColor = nil
        return onDrop?(sender.draggingPasteboard) ?? false
    }
}

/// A button that runs a closure.
final class ClosureButton: NSButton {
    private var handler: () -> Void = {}

    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.handler = handler
        target = self
        action = #selector(run)
    }

    @objc private func run() { handler() }
}

private final class PageCardView: NSView, NSDraggingSource {
    private let card: PageCard
    private var hovering = false { didSet { needsDisplay = true } }
    private var dropping = false { didSet { needsDisplay = true } }
    private var mouseDownAt: NSPoint?
    private var dragged = false

    init(card: PageCard) {
        self.card = card
        super.init(frame: .zero)
        if card.onDrop != nil { registerForDraggedTypes(FavoriteDrag.acceptedTypes) }
        let icon: NSView
        if card.tiled, let image = card.image {
            let tile = NSView()
            tile.wantsLayer = true
            tile.layer?.cornerRadius = 8
            tile.layer?.cornerCurve = .continuous
            tile.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            let inner = NSImageView(image: image)
            inner.imageScaling = .scaleProportionallyUpOrDown
            inner.frame = NSRect(x: 8, y: 8, width: 20, height: 20)
            tile.addSubview(inner)
            icon = tile
        } else {
            let view = NSImageView(image: card.image ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)!)
            view.imageScaling = .scaleProportionallyUpOrDown
            icon = view
        }
        icon.alphaValue = card.struck ? 0.45 : 1
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .medium),
            .foregroundColor: card.struck ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .strikethroughStyle: card.struck ? NSUnderlineStyle.single.rawValue : 0,
        ]
        title.attributedStringValue = NSAttributedString(string: card.title, attributes: attributes)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let status = NSTextField(labelWithString: card.status ?? "")
        status.font = .systemFont(ofSize: 12.5)
        status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleRow = NSStackView(views: [title, status])
        titleRow.spacing = 10
        let detail = NSTextField(labelWithString: card.detail ?? "")
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.isHidden = card.detail == nil
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let texts = NSStackView(views: [titleRow, detail]).vertical()
        texts.spacing = 3
        texts.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView(views: card.actions.map { action in
            let button = IconButton(symbol: action.symbol, label: action.label, target: nil, action: nil)
            button.pointSize = 13
            button.toolTip = action.label
            let target = ActionTarget(action.handler)
            button.target = target
            button.action = #selector(ActionTarget.run)
            objc_setAssociatedObject(button, "target", target, .OBJC_ASSOCIATION_RETAIN)
            return button
        })
        actions.spacing = 4
        actions.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(texts)
        addSubview(actions)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 36),
            icon.heightAnchor.constraint(equalToConstant: 36),
            texts.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let fill = dropping ? NSColor.controlAccentColor.withAlphaComponent(0.3)
            : NSColor.labelColor.withAlphaComponent(hovering && card.onOpen != nil ? 0.09 : 0.055)
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        if dropping {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 11, yRadius: 11)
            path.lineWidth = 2
            path.stroke()
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let start = mouseDownAt, let make = card.dragItem,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        dragged = true
        let item = NSDraggingItem(pasteboardWriter: make())
        let snapshot = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            snapshot.addRepresentation(rep)
        }
        item.setDraggingFrame(bounds, contents: snapshot)
        alphaValue = 0.4
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownAt = nil }
        guard !dragged, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        card.onOpen?()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        alphaValue = 1
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropping = true
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropping = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropping = false
        return card.onDrop?(sender.draggingPasteboard) ?? false
    }
}

private final class ActionTarget: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}

// MARK: - Downloads

final class DownloadsPageView: ListPageView {
    init(open: @escaping (URL, OpenDisposition) -> Void) {
        super.init(page: .downloads, open: open)
        observe(DownloadManager.didChange)
        setHeaderButtons([("Clear All", { DownloadManager.shared.clearAll() })])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var emptyText: String { "Files you download appear here" }

    override func sections(matching query: String) -> [PageSection] {
        let items = DownloadManager.shared.items.filter {
            query.isEmpty || $0.filename.lowercased().contains(query) || ($0.sourceURL?.absoluteString.lowercased().contains(query) ?? false)
        }
        return Self.grouped(items, date: \.date) { item in
            let missing = item.isMissing
            var card = PageCard(title: item.filename, detail: item.sourceURL?.host)
            card.tiled = false
            if let destination = item.destination, !missing, item.state == .finished {
                card.image = NSWorkspace.shared.icon(forFile: destination.path)
            } else {
                let ext = (item.filename as NSString).pathExtension
                card.image = NSWorkspace.shared.icon(for: .init(filenameExtension: ext) ?? .data)
            }
            switch item.state {
            case .running:
                if let progress = item.progress, progress.totalUnitCount > 0 {
                    card.status = "\(ByteCountFormatter.string(fromByteCount: progress.completedUnitCount, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalUnitCount, countStyle: .file))"
                } else {
                    card.status = "Starting…"
                }
                card.actions.append(PageAction(symbol: "xmark.circle", label: "Cancel") { DownloadManager.shared.cancel(item) })
            case .finished where missing:
                card.status = "Deleted"
                card.struck = true
            case .finished:
                card.status = item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                card.onOpen = { if let destination = item.destination { NSWorkspace.shared.open(destination) } }
                card.actions.append(PageAction(symbol: "folder", label: "Show in Finder") {
                    if let destination = item.destination { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                })
            case .failed:
                card.status = "Failed"
                card.struck = true
            case .cancelled:
                card.status = "Canceled"
                card.struck = true
            }
            if let source = item.sourceURL {
                card.actions.append(PageAction(symbol: "link", label: "Copy Download Link") { Self.copy(source.absoluteString) })
            }
            card.actions.append(PageAction(symbol: "xmark", label: "Remove from List") { DownloadManager.shared.remove(item) })
            return card
        }
    }
}

// MARK: - History

final class HistoryPageView: ListPageView {
    init(open: @escaping (URL, OpenDisposition) -> Void) {
        super.init(page: .history, open: open)
        observe(HistoryStore.didChange)
        setHeaderButtons([("Clear History…", { [weak self] in self?.confirmClear() })])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var emptyText: String { "Pages you visit appear here" }

    override func sections(matching query: String) -> [PageSection] {
        let entries = HistoryStore.shared.sorted.filter {
            query.isEmpty || $0.title.lowercased().contains(query) || $0.url.lowercased().contains(query)
        }.prefix(400)
        return Self.grouped(Array(entries), date: \.lastVisit) { entry in
            let url = URL(string: entry.url)
            var card = PageCard(image: FaviconCache.shared.image(for: url?.host) ?? NSImage.monogram(for: url?.host),
                                title: entry.title.isEmpty ? AddressInput.display(url) : entry.title,
                                status: entry.lastVisit.formatted(date: .omitted, time: .shortened),
                                detail: AddressInput.display(url))
            card.onOpen = { [weak self] in
                if let url { self?.open(url, NSApp.currentEvent?.modifierFlags.contains(.command) == true ? .backgroundTab : .current) }
            }
            card.actions = [
                PageAction(symbol: "link", label: "Copy Link") { Self.copy(entry.url) },
                PageAction(symbol: "xmark", label: "Remove from History") { HistoryStore.shared.remove([entry.url]) },
            ]
            return card
        }
    }

    private func confirmClear() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear all history?"
        alert.informativeText = "Websites you visited are removed from History and from address suggestions. Cookies and saved passwords stay."
        alert.addButton(withTitle: "Clear History").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { HistoryStore.shared.clear() }
        }
    }
}

// MARK: - Favorites

final class FavoritesPageView: ListPageView {
    /// The folders opened, outermost first (empty = the Favorites bar).
    private var path: [UUID] = []

    init(open: @escaping (URL, OpenDisposition) -> Void) {
        super.init(page: .favorites, open: open)
        observe(BookmarkStore.didChange)
        setHeaderButtons([
            ("Add Favorite…", { [weak self] in self?.addFavorite() }),
            ("New Folder…", { [weak self] in self?.newFolder() }),
            ("Import from Chrome", { AppDelegate.shared.importChromeBookmarks(nil) }),
        ])
        // Between cards: reorder (or a link dragged in becomes a favorite here).
        onReorderDrop = { [weak self] index, pasteboard in self?.drop(pasteboard, into: self?.path.last, at: index) ?? false }
        // On a breadcrumb step: up into that folder (step 0 = the bar).
        onBreadcrumbDrop = { [weak self] step, pasteboard in
            guard let self else { return false }
            return self.drop(pasteboard, into: step == 0 ? nil : self.path[step - 1], at: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var emptyText: String { "Press ⌘D on any page, drag a link here, or use Add Favorite…" }

    private var currentNodes: [Bookmark] {
        var nodes = BookmarkStore.shared.bar
        var valid: [UUID] = []
        for id in path {
            guard let folder = nodes.first(where: { $0.id == id }), let children = folder.children else { break }
            nodes = children
            valid.append(id)
        }
        if valid != path { path = valid }
        return nodes
    }

    override func sections(matching query: String) -> [PageSection] {
        // Breadcrumb: Favorites Bar › Work › … (shown inside a folder; each step takes drops).
        var crumbs: [(String, () -> Void)] = [("Favorites Bar", { [weak self] in self?.path = []; self?.reload() })]
        var nodes = BookmarkStore.shared.bar
        for (depth, id) in path.enumerated() {
            guard let folder = nodes.first(where: { $0.id == id }) else { break }
            crumbs.append((folder.title, { [weak self] in self?.path = Array(self?.path.prefix(depth + 1) ?? []); self?.reload() }))
            nodes = folder.children ?? []
        }
        breadcrumb = path.isEmpty ? [] : crumbs

        let list: [Bookmark] = query.isEmpty ? currentNodes : BookmarkStore.shared.allPages.filter {
            $0.title.lowercased().contains(query) || ($0.url?.lowercased().contains(query) ?? false)
        }
        return [PageSection(title: "", cards: list.map(card(for:)))]
    }

    /// A favorite moved (by id) or a link added, into `folder` (nil = the bar) at `index`.
    private func drop(_ pasteboard: NSPasteboard, into folder: UUID?, at index: Int?) -> Bool {
        let drag = FavoriteDrag.read(pasteboard)
        if let id = drag.id {
            BookmarkStore.shared.move(id: id, into: folder, at: index)
            return true
        }
        guard let url = drag.url else { return false }
        BookmarkStore.shared.add(url: url, title: drag.title ?? "", into: folder, at: index)
        return true
    }

    private func card(for bookmark: Bookmark) -> PageCard {
        let move = PageAction(symbol: "arrowshape.turn.up.right", label: "Move to…") { [weak self] in self?.moveMenu(for: bookmark) }
        if bookmark.isFolder {
            var card = PageCard(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                                    .withSymbolConfiguration(.init(paletteColors: [.controlAccentColor])),
                                title: bookmark.title, detail: "\(bookmark.children?.count ?? 0) items")
            card.onOpen = { [weak self] in
                self?.path.append(bookmark.id)
                self?.search.stringValue = ""
                self?.searchRow.refresh()
                self?.reload()
            }
            card.dragItem = { FavoriteDrag.item(for: bookmark) }
            card.onDrop = { [weak self] pasteboard in
                guard FavoriteDrag.read(pasteboard).id != bookmark.id else { return false }
                return self?.drop(pasteboard, into: bookmark.id, at: nil) ?? false
            }
            card.actions = [
                PageAction(symbol: "pencil", label: "Rename") { [weak self] in self?.rename(bookmark) },
                move,
                PageAction(symbol: "trash", label: "Delete Folder") { [weak self] in self?.delete(bookmark) },
            ]
            return card
        }
        let url = bookmark.url.flatMap(URL.init(string:))
        var card = PageCard(image: FaviconCache.shared.image(for: url?.host) ?? NSImage.monogram(for: url?.host),
                            title: bookmark.title, detail: AddressInput.display(url))
        card.onOpen = { [weak self] in
            if let url { self?.open(url, NSApp.currentEvent?.modifierFlags.contains(.command) == true ? .backgroundTab : .current) }
        }
        card.dragItem = { FavoriteDrag.item(for: bookmark) }
        card.actions = [
            PageAction(symbol: "pencil", label: "Rename") { [weak self] in self?.rename(bookmark) },
            move,
            PageAction(symbol: "link", label: "Copy Link") { Self.copy(bookmark.url ?? "") },
            PageAction(symbol: "trash", label: "Delete") { BookmarkStore.shared.remove(id: bookmark.id) },
        ]
        return card
    }

    /// "Move to…": the Favorites bar and every folder (indented), except the item itself and what it holds.
    private func moveMenu(for bookmark: Bookmark) {
        let menu = NSMenu()
        let here = BookmarkStore.shared.location(of: bookmark.id)?.folder
        let top = ClosureMenuItem(title: "Favorites Bar") { BookmarkStore.shared.move(id: bookmark.id, into: nil, at: nil) }
        top.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        top.state = here == nil ? .on : .off
        menu.addItem(top)
        for (folder, depth) in BookmarkStore.shared.folders where !BookmarkStore.shared.isWithin(folder.id, folder: bookmark.id) {
            let item = ClosureMenuItem(title: folder.title) { BookmarkStore.shared.move(id: bookmark.id, into: folder.id, at: nil) }
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            item.indentationLevel = depth + 1
            item.state = here == folder.id ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func addFavorite() {
        let alert = NSAlert()
        alert.messageText = "Add Favorite"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let name = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
        name.placeholderString = "Name"
        let address = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        address.placeholderString = "Address (example.com)"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 54))
        box.addSubview(name)
        box.addSubview(address)
        alert.accessoryView = box
        alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = AddressInput.url(for: address.stringValue), url != AddressInput.searchURL(for: address.stringValue) else { return }
        BookmarkStore.shared.add(url: url, title: name.stringValue.trimmingCharacters(in: .whitespaces), into: path.last, at: nil)
    }

    private func rename(_ bookmark: Bookmark) {
        guard let name = TextPrompt.ask(title: "Rename", message: "", value: bookmark.title, in: window) else { return }
        BookmarkStore.shared.rename(id: bookmark.id, to: name)
    }

    private func delete(_ folder: Bookmark) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(folder.title)” and the \(folder.children?.count ?? 0) favorites in it?"
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { BookmarkStore.shared.remove(id: folder.id) }
    }

    private func newFolder() {
        guard let name = TextPrompt.ask(title: "New Folder", message: "Name the folder.", value: "New Folder", in: window) else { return }
        BookmarkStore.shared.addFolder(named: name, in: path.last)
    }
}
