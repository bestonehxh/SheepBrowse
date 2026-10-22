import AppKit

/// A favorite: a page (url) or a folder (children).
struct Bookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var url: String?
    var children: [Bookmark]?

    var isFolder: Bool { children != nil }
}

/// Favorites, shown on the Favorites bar (folders open as menus). Saved in bookmarks.json.
final class BookmarkStore {
    static let shared = BookmarkStore()
    static let didChange = Notification.Name("SheepBrowseBookmarksDidChange")

    private(set) var bar: [Bookmark]

    private init() {
        bar = AppFiles.read([Bookmark].self, from: "bookmarks.json") ?? []
    }

    private func changed() {
        AppFiles.write(bar, to: "bookmarks.json")
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Every page in every folder.
    var allPages: [Bookmark] {
        func walk(_ nodes: [Bookmark]) -> [Bookmark] {
            nodes.flatMap { $0.isFolder ? walk($0.children ?? []) : [$0] }
        }
        return walk(bar)
    }

    /// Sync: the favorites as another Mac has them.
    func replaceAll(_ nodes: [Bookmark]) {
        guard nodes != bar else { return }
        bar = nodes
        changed()
    }

    func bookmark(for url: URL?) -> Bookmark? {
        guard let key = url?.absoluteString else { return nil }
        return allPages.first { $0.url == key }
    }

    func add(url: URL, title: String) {
        add(url: url, title: title, into: nil, at: nil)
    }

    /// A page into `folder` (nil = the bar) at `index` (nil = the end). A page already saved is not added twice.
    func add(url: URL, title: String, into folder: UUID?, at index: Int?) {
        guard bookmark(for: url) == nil else { return }
        let node = Bookmark(title: title.isEmpty ? (url.host ?? url.absoluteString) : title, url: url.absoluteString)
        insert(node, into: folder, at: index)
        changed()
    }

    // MARK: Tree

    /// The nodes in `folder` (nil = the bar).
    func children(of folder: UUID?) -> [Bookmark] {
        guard let folder else { return bar }
        return node(folder)?.children ?? []
    }

    func node(_ id: UUID) -> Bookmark? {
        func find(_ nodes: [Bookmark]) -> Bookmark? {
            for node in nodes {
                if node.id == id { return node }
                if let found = node.children.flatMap(find) { return found }
            }
            return nil
        }
        return find(bar)
    }

    /// The folder holding `id` (nil = the bar), and its index there.
    func location(of id: UUID) -> (folder: UUID?, index: Int)? {
        if let index = bar.firstIndex(where: { $0.id == id }) { return (nil, index) }
        func find(_ nodes: [Bookmark]) -> (UUID?, Int)? {
            for node in nodes {
                if let children = node.children {
                    if let index = children.firstIndex(where: { $0.id == id }) { return (node.id, index) }
                    if let found = find(children) { return found }
                }
            }
            return nil
        }
        return find(bar)
    }

    /// Every folder with its depth, in tree order (for "Move to…").
    var folders: [(Bookmark, Int)] {
        func walk(_ nodes: [Bookmark], _ depth: Int) -> [(Bookmark, Int)] {
            nodes.flatMap { $0.isFolder ? [($0, depth)] + walk($0.children ?? [], depth + 1) : [] }
        }
        return walk(bar, 0)
    }

    /// True when `id` is `folder` or inside it (a folder can't be moved into itself).
    func isWithin(_ id: UUID, folder: UUID) -> Bool {
        guard let start = node(folder) else { return false }
        if start.id == id { return true }
        func walk(_ nodes: [Bookmark]) -> Bool { nodes.contains { $0.id == id || walk($0.children ?? []) } }
        return walk(start.children ?? [])
    }

    /// Moves `id` into `folder` (nil = the bar) at `index` — the position among the destination's items
    /// as they are BEFORE the move (nil = the end).
    func move(id: UUID, into folder: UUID?, at index: Int?) {
        guard let moving = node(id), let from = location(of: id) else { return }
        if let folder, isWithin(folder, folder: id) { return }
        var target = index
        if let index, from.folder == folder, from.index < index { target = index - 1 }
        if from.folder == folder, target == from.index { return }
        remove(id, from: &bar)
        insert(moving, into: folder, at: target)
        changed()
    }

    private func remove(_ id: UUID, from nodes: inout [Bookmark]) {
        nodes.removeAll { $0.id == id }
        for index in nodes.indices where nodes[index].children != nil { remove(id, from: &nodes[index].children!) }
    }

    private func insert(_ node: Bookmark, into folder: UUID?, at index: Int?) {
        guard let folder else {
            bar.insert(node, at: min(max(0, index ?? bar.count), bar.count))
            return
        }
        func walk(_ nodes: inout [Bookmark]) -> Bool {
            for i in nodes.indices {
                if nodes[i].id == folder, nodes[i].children != nil {
                    let count = nodes[i].children!.count
                    nodes[i].children!.insert(node, at: min(max(0, index ?? count), count))
                    return true
                }
                if nodes[i].children != nil, walk(&nodes[i].children!) { return true }
            }
            return false
        }
        if !walk(&bar) { bar.append(node) }
    }

    func remove(id: UUID) {
        func strip(_ nodes: [Bookmark]) -> [Bookmark] {
            nodes.compactMap { node in
                guard node.id != id else { return nil }
                var copy = node
                if let children = node.children { copy.children = strip(children) }
                return copy
            }
        }
        bar = strip(bar)
        changed()
    }

    func rename(id: UUID, to title: String) {
        func walk(_ nodes: inout [Bookmark]) {
            for index in nodes.indices {
                if nodes[index].id == id { nodes[index].title = title }
                if nodes[index].children != nil { walk(&nodes[index].children!) }
            }
        }
        walk(&bar)
        changed()
    }

    /// A new folder on the bar, or inside the folder `parent`.
    func addFolder(named name: String, in parent: UUID? = nil) {
        let folder = Bookmark(title: name, children: [])
        guard let parent else {
            bar.append(folder)
            return changed()
        }
        func insert(_ nodes: inout [Bookmark]) {
            for index in nodes.indices {
                if nodes[index].id == parent { nodes[index].children?.append(folder) }
                if nodes[index].children != nil { insert(&nodes[index].children!) }
            }
        }
        insert(&bar)
        changed()
    }

    // MARK: Import from Chrome

    /// Chrome keeps bookmarks as plain JSON in its profile folder. Imports the bookmarks bar (and "Other
    /// bookmarks" as a folder), skipping pages already here. Returns how many pages were added.
    func importFromChrome() -> Int? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        var candidates = [base.appendingPathComponent("Default/Bookmarks")]
        if let profiles = try? FileManager.default.contentsOfDirectory(atPath: base.path) {
            candidates += profiles.filter { $0.hasPrefix("Profile ") }.sorted()
                .map { base.appendingPathComponent("\($0)/Bookmarks") }
        }
        guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { return nil }

        let existing = Set(allPages.compactMap(\.url))
        var added = 0
        func convert(_ node: [String: Any]) -> Bookmark? {
            let name = node["name"] as? String ?? ""
            if node["type"] as? String == "url" {
                guard let url = node["url"] as? String, !existing.contains(url) else { return nil }
                added += 1
                return Bookmark(title: name, url: url)
            }
            let children = (node["children"] as? [[String: Any]] ?? []).compactMap(convert)
            return children.isEmpty ? nil : Bookmark(title: name, children: children)
        }
        if let barRoot = roots["bookmark_bar"] as? [String: Any] {
            bar += (barRoot["children"] as? [[String: Any]] ?? []).compactMap(convert)
        }
        if let other = roots["other"] as? [String: Any], var folder = convert(other) {
            folder.title = "Other Bookmarks"
            bar.append(folder)
        }
        changed()
        return added
    }
}

// MARK: - Favorites bar

@MainActor
protocol FavoritesBarDelegate: AnyObject {
    func favoritesBar(open url: URL, disposition: OpenDisposition)
}

enum OpenDisposition {
    case current, newTab, backgroundTab, newWindow
}

final class FavoritesBarView: WindowDragView {
    /// The buttons sit 7 pt above the header's bottom edge and 8 pt below the address capsule (the nav
    /// bar's own 8 pt margin + 0): the same space above and below.
    static let height: CGFloat = 31
    weak var delegate: FavoritesBarDelegate?
    private var buttons: [FavoriteButton] = []
    private let overflow = IconButton(symbol: "chevron.right.2", label: "More Favorites", target: nil, action: nil)
    private var observer: NSObjectProtocol?
    /// Where a drop would land: a line between buttons.
    private let dropLine = NSBox()
    private weak var dropFolder: FavoriteButton?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(FavoriteDrag.acceptedTypes)
        dropLine.boxType = .custom
        dropLine.fillColor = .controlAccentColor
        dropLine.borderWidth = 0
        dropLine.cornerRadius = 1
        dropLine.isHidden = true
        addSubview(dropLine)
        overflow.pointSize = 11
        overflow.target = self
        overflow.action = #selector(showOverflow)
        addSubview(overflow)
        observer = NotificationCenter.default.addObserver(forName: BookmarkStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = BookmarkStore.shared.bar.map { bookmark in
            let button = FavoriteButton(bookmark: bookmark, bar: self)
            addSubview(button)
            return button
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 12
        let limit = bounds.width - 40
        var hidden = false
        for button in buttons {
            let width = min(170, button.fittingWidth)
            if x + width > limit { hidden = true }
            button.isHidden = hidden
            button.frame = NSRect(x: x, y: 7, width: width, height: 24)
            x += width + 2
        }
        overflow.isHidden = !hidden
        overflow.frame = NSRect(x: bounds.width - 38, y: 6, width: 28, height: 26)
    }

    @objc private func showOverflow() {
        let menu = NSMenu()
        for button in buttons where button.isHidden { menu.addItem(menuItem(for: button.bookmark)) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: overflow.bounds.height + 4), in: overflow)
    }

    fileprivate func open(_ bookmark: Bookmark, disposition: OpenDisposition) {
        guard let string = bookmark.url, let url = URL(string: string) else { return }
        delegate?.favoritesBar(open: url, disposition: disposition)
    }

    fileprivate func showFolder(_ bookmark: Bookmark, from button: NSView) {
        let menu = NSMenu()
        for child in bookmark.children ?? [] { menu.addItem(menuItem(for: child)) }
        if (bookmark.children ?? []).contains(where: { !$0.isFolder }) {
            menu.addItem(.separator())
            let all = NSMenuItem(title: "Open All in Tabs", action: #selector(openAll(_:)), keyEquivalent: "")
            all.target = self
            all.representedObject = bookmark.id
            menu.addItem(all)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    func menuItem(for bookmark: Bookmark) -> NSMenuItem {
        let item = NSMenuItem(title: bookmark.title, action: nil, keyEquivalent: "")
        if bookmark.isFolder {
            item.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            let submenu = NSMenu()
            for child in bookmark.children ?? [] { submenu.addItem(menuItem(for: child)) }
            item.submenu = submenu
        } else {
            item.action = #selector(openMenuItem(_:))
            item.target = self
            item.representedObject = bookmark.url
            let host = bookmark.url.flatMap(URL.init(string:))?.host
            let image = FaviconCache.shared.image(for: host) ?? NSImage.monogram(for: host)
            image.size = NSSize(width: 16, height: 16)
            item.image = image
        }
        return item
    }

    @objc private func openMenuItem(_ sender: NSMenuItem) {
        guard let string = sender.representedObject as? String, let url = URL(string: string) else { return }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        delegate?.favoritesBar(open: url, disposition: flags.contains(.command) ? .backgroundTab : .current)
    }

    @objc private func openAll(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let folder = BookmarkStore.shared.bar.first(where: { $0.id == id }) else { return }
        for child in folder.children ?? [] {
            if let string = child.url, let url = URL(string: string) { delegate?.favoritesBar(open: url, disposition: .backgroundTab) }
        }
    }

    fileprivate func contextMenu(for bookmark: Bookmark) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ handler: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, handler: handler)
            menu.addItem(item)
        }
        if !bookmark.isFolder {
            add("Open in New Tab") { [weak self] in self?.open(bookmark, disposition: .backgroundTab) }
            add("Open in New Window") { [weak self] in self?.open(bookmark, disposition: .newWindow) }
            menu.addItem(.separator())
        }
        add("Rename…") { [weak self] in self?.rename(bookmark) }
        add("Delete") { BookmarkStore.shared.remove(id: bookmark.id) }
        menu.addItem(.separator())
        add("New Folder…") { [weak self] in self?.newFolder() }
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "New Folder…") { [weak self] in self?.newFolder() })
        menu.addItem(ClosureMenuItem(title: "Import Favorites from Chrome") { AppDelegate.shared.importChromeBookmarks(nil) })
        return menu
    }

    private func rename(_ bookmark: Bookmark) {
        guard let name = TextPrompt.ask(title: "Rename", message: "", value: bookmark.title, in: window) else { return }
        BookmarkStore.shared.rename(id: bookmark.id, to: name)
    }

    private func newFolder() {
        guard let name = TextPrompt.ask(title: "New Folder", message: "Name the folder.", value: "New Folder", in: window) else { return }
        BookmarkStore.shared.addFolder(named: name)
    }

    // MARK: Drop: reorder, into a folder, or a new favorite (a link or a page dragged from elsewhere)

    /// Over the middle of a folder = into it; anywhere else = between buttons (the index before which).
    private func target(at point: NSPoint, dragging id: UUID?) -> (folder: FavoriteButton?, index: Int) {
        let visible = buttons.filter { !$0.isHidden }
        if let folder = visible.first(where: { $0.bookmark.isFolder && $0.frame.insetBy(dx: $0.frame.width * 0.22, dy: -6).contains(point) }),
           folder.bookmark.id != id {
            return (folder, 0)
        }
        let index = visible.filter { $0.frame.midX < point.x }.count
        return (nil, index)
    }

    private func showDrop(_ target: (folder: FavoriteButton?, index: Int)) {
        dropFolder?.isDropTarget = false
        dropFolder = target.folder
        target.folder?.isDropTarget = true
        dropLine.isHidden = target.folder != nil
        let visible = buttons.filter { !$0.isHidden }
        let x = target.index < visible.count ? visible[target.index].frame.minX - 2 : (visible.last?.frame.maxX ?? 10) + 1
        dropLine.frame = NSRect(x: x - 1, y: 8, width: 2, height: 22)
    }

    private func clearDrop() {
        dropFolder?.isDropTarget = false
        dropFolder = nil
        dropLine.isHidden = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let drag = FavoriteDrag.read(sender.draggingPasteboard)
        guard drag.id != nil || drag.url != nil else { return [] }
        showDrop(target(at: convert(sender.draggingLocation, from: nil), dragging: drag.id))
        return drag.id != nil ? .move : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { clearDrop() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let drag = FavoriteDrag.read(sender.draggingPasteboard)
        let spot = target(at: convert(sender.draggingLocation, from: nil), dragging: drag.id)
        clearDrop()
        let folder = spot.folder?.bookmark.id
        if let id = drag.id {
            BookmarkStore.shared.move(id: id, into: folder, at: folder == nil ? spot.index : nil)
            return true
        }
        guard let url = drag.url else { return false }
        BookmarkStore.shared.add(url: url, title: drag.title ?? "", into: folder, at: folder == nil ? spot.index : nil)
        return true
    }
}

/// What a favorite carries when dragged (its id, and its URL for other apps), and what a drop can read.
enum FavoriteDrag {
    static let type = NSPasteboard.PasteboardType("com.bestchaan.sheepbrowse.favorite")
    static let acceptedTypes: [NSPasteboard.PasteboardType] = [type, .URL, NSPasteboard.PasteboardType("public.url")]

    static func item(for bookmark: Bookmark) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(bookmark.id.uuidString, forType: type)
        if let url = bookmark.url {
            item.setString(url, forType: .URL)
            item.setString(url, forType: .string)
        }
        return item
    }

    static func read(_ pasteboard: NSPasteboard) -> (id: UUID?, url: URL?, title: String?) {
        if let raw = pasteboard.string(forType: type), let id = UUID(uuidString: raw) { return (id, nil, nil) }
        let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first { ["http", "https"].contains($0.scheme ?? "") }
        let title = pasteboard.string(forType: NSPasteboard.PasteboardType("public.url-name"))
        return (nil, url, title)
    }
}

private final class FavoriteButton: NSView, NSDraggingSource {
    let bookmark: Bookmark
    private weak var bar: FavoritesBarView?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hovering = false { didSet { needsDisplay = true } }
    var isDropTarget = false { didSet { needsDisplay = true } }

    init(bookmark: Bookmark, bar: FavoritesBarView) {
        self.bookmark = bookmark
        self.bar = bar
        super.init(frame: .zero)
        if bookmark.isFolder {
            icon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            icon.contentTintColor = .controlAccentColor
        } else {
            let host = bookmark.url.flatMap(URL.init(string:))?.host
            icon.image = FaviconCache.shared.image(for: host) ?? NSImage.monogram(for: host)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.stringValue = bookmark.title
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(label)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    var fittingWidth: CGFloat {
        label.sizeToFit()
        return 9 + 14 + 6 + ceil(label.frame.width) + (bookmark.isFolder ? 4 : 0) + 10
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 9, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: 29, y: (bounds.height - 16) / 2, width: bounds.width - 29 - 8, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering || isDropTarget else { return }
        (isDropTarget ? NSColor.controlAccentColor.withAlphaComponent(0.35) : NSColor.labelColor.withAlphaComponent(0.07)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        alphaValue = 1
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override var mouseDownCanMoveWindow: Bool { false }

    /// A click opens; moving the pointer 4 pt starts a drag (onto the bar, a folder, the Favorites page,
    /// or another app as a link).
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 4 {
                let item = NSDraggingItem(pasteboardWriter: FavoriteDrag.item(for: bookmark))
                let snapshot = NSImage(size: bounds.size)
                if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
                    cacheDisplay(in: bounds, to: rep)
                    snapshot.addRepresentation(rep)
                }
                item.setDraggingFrame(bounds, contents: snapshot)
                alphaValue = 0.4
                beginDraggingSession(with: [item], event: event, source: self)
                return
            }
        }
        if bookmark.isFolder {
            bar?.showFolder(bookmark, from: self)
        } else {
            let flags = event.modifierFlags
            bar?.open(bookmark, disposition: flags.contains(.command) ? (flags.contains(.shift) ? .newTab : .backgroundTab) : .current)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, !bookmark.isFolder { bar?.open(bookmark, disposition: .backgroundTab) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { bar?.contextMenu(for: bookmark) }
}

// MARK: - Small shared helpers

/// A menu item that runs a closure.
nonisolated final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

enum TextPrompt {
    /// A small modal text prompt (sheet-free, for short edits).
    static func ask(title: String, message: String, value: String, in window: NSWindow?) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
