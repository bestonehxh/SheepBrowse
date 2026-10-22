import AppKit
import WebKit

@MainActor
protocol TabStripDelegate: AnyObject {
    func tabStripSelect(_ tab: BrowserTab)
    func tabStripClose(_ tab: BrowserTab)
    /// The tab was dragged to a new place among the tabs.
    func tabStripMove(_ tab: BrowserTab, to index: Int)
    func tabStripNewTab()
    /// The tab was dragged out of the strip and dropped at `screenPoint`.
    func tabStripDetach(_ tab: BrowserTab, at screenPoint: NSPoint)
    func tabStripMenu(for tab: BrowserTab) -> NSMenu
    func tabStripToggleMute(_ tab: BrowserTab)
    /// Chrome's tab search (open tabs and recently closed).
    func tabStripSearch(from button: NSView)
}

/// Chrome's tab row, at the top of the window beside the traffic lights. The selected tab is a Liquid
/// Glass capsule; the others are plain with hairline separators. Tabs share the width (up to 220 pt)
/// and stay put while the pointer is in the strip after a close, so the next ✕ is under the pointer.
final class TabStripView: WindowDragView {
    static let height: CGFloat = 40
    weak var delegate: TabStripDelegate?

    private(set) var items: [TabItemView] = []
    private let newTabButton: IconButton
    /// The ⌄ at the left of the tabs: search open and recently closed tabs.
    let searchButton: IconButton
    /// The Google account at the right end of the row (hidden in private windows).
    let accountButton = AccountButton()
    private var accountSpace: CGFloat { accountButton.isHidden ? 0 : accountButton.preferredWidth + 18 }
    private var selectedID: UUID?
    private var frozenWidth: CGFloat?
    private var dragging: TabItemView?

    /// Room for the traffic lights.
    var leadingInset: CGFloat = 80 { didSet { if oldValue != leadingInset { needsLayout = true } } }
    /// Tabs are centred on the traffic lights (distance from the strip's top).
    var centerFromTop: CGFloat = 20 { didSet { if oldValue != centerFromTop { needsLayout = true } } }
    static let tabHeight: CGFloat = 28
    private var tabY: CGFloat { round(bounds.height - centerFromTop - Self.tabHeight / 2) }

    override init(frame: NSRect) {
        newTabButton = IconButton(symbol: "plus", label: "New Tab", target: nil, action: nil)
        searchButton = IconButton(symbol: "chevron.down", label: "Search Tabs", target: nil, action: nil)
        super.init(frame: frame)
        searchButton.target = self
        searchButton.action = #selector(searchTabs)
        searchButton.pointSize = 11
        searchButton.weight = .bold
        addSubview(searchButton)
        addSubview(accountButton)
        newTabButton.target = self
        newTabButton.action = #selector(newTab)
        newTabButton.pointSize = 14
        addSubview(newTabButton)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func newTab() { delegate?.tabStripNewTab() }
    @objc private func searchTabs() { delegate?.tabStripSearch(from: searchButton) }

    /// Where the first tab starts (after the search button).
    private var tabsStart: CGFloat { leadingInset + 34 }

    /// Matches the views to the tabs (reusing a tab's view), then lays out.
    func reload(tabs: [BrowserTab], selected: BrowserTab?, animated: Bool) {
        var byID = Dictionary(uniqueKeysWithValues: items.map { ($0.tab.id, $0) })
        var next: [TabItemView] = []
        for tab in tabs {
            if let view = byID.removeValue(forKey: tab.id) {
                next.append(view)
            } else {
                let view = TabItemView(tab: tab, strip: self)
                view.frame = NSRect(x: (items.last?.frame.maxX ?? tabsStart), y: tabY, width: 0, height: Self.tabHeight)
                addSubview(view, positioned: .below, relativeTo: newTabButton)
                next.append(view)
            }
        }
        for gone in byID.values { gone.removeFromSuperview() }
        items = next
        selectedID = selected?.id
        for item in items { item.isActive = item.tab.id == selectedID }
        layoutTabs(animated: animated)
        refreshAll()
    }

    func refresh(_ tab: BrowserTab) {
        items.first { $0.tab === tab }?.refresh()
        needsDisplay = true
    }

    func refreshAll() {
        items.forEach { $0.refresh() }
        needsDisplay = true
    }

    // MARK: Layout

    /// Where the tabs must end: the + button and the account sit after it.
    private var tabsLimit: CGFloat { bounds.width - 40 - accountSpace }

    /// Each tab's width, counting the 2 pt gap after every tab (left out before 1.0 (11), many tabs ran
    /// under the + button).
    private func standardWidth(for count: Int, pinned: Int) -> CGFloat {
        let unpinned = max(1, count - pinned)
        let available = tabsLimit - tabsStart - CGFloat(pinned) * 42 - CGFloat(unpinned) * 2
        // Down to an icon's width (24 pt) so many tabs in a narrow window still end before + and the account.
        return min(220, max(24, floor(available / CGFloat(unpinned))))
    }

    private func frames() -> [NSRect] {
        let pinned = items.filter { $0.tab.isPinned }.count
        var width = frozenWidth ?? standardWidth(for: items.count, pinned: pinned)
        // A width kept after a close must not push the last tab under the + button either.
        let needed = tabsStart + CGFloat(pinned) * 42 + CGFloat(items.count - pinned) * (width + 2)
        if needed > tabsLimit { width = standardWidth(for: items.count, pinned: pinned) }
        var x = tabsStart
        return items.map { item in
            let w = item.tab.isPinned ? 40 : width
            defer { x += w + 2 }
            return NSRect(x: x, y: tabY, width: w, height: Self.tabHeight)
        }
    }

    override func layout() {
        super.layout()
        layoutTabs(animated: false)
    }

    func layoutTabs(animated: Bool) {
        let rects = frames()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.18 : 0
            context.allowsImplicitAnimation = animated
            for (item, rect) in zip(items, rects) where item !== dragging {
                (animated ? item.animator() : item).frame = rect
            }
            searchButton.frame = NSRect(x: leadingInset, y: tabY, width: 28, height: 28)
            let plusX = min((rects.last?.maxX ?? tabsStart) + 6, bounds.width - 34 - accountSpace)
            let accountWidth = accountButton.preferredWidth
            accountButton.frame = NSRect(x: bounds.width - 12 - accountWidth, y: tabY, width: accountWidth, height: 28)
            (animated ? newTabButton.animator() : newTabButton).frame = NSRect(x: plusX, y: tabY, width: 28, height: 28)
        }
        needsDisplay = true
    }

    /// Separators between two plain tabs (none next to the selected or hovered one).
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        for (left, right) in zip(items, items.dropFirst()) {
            guard !left.isActive, !right.isActive, !left.isHovering, !right.isHovering,
                  left !== dragging, right !== dragging else { continue }
            NSRect(x: round(left.frame.maxX), y: tabY + 7, width: 1, height: 14).fill()
        }
    }

    // MARK: Closing keeps widths while the pointer stays

    func closeClicked(_ item: TabItemView) {
        if !item.tab.isPinned { frozenWidth = item.frame.width }
        delegate?.tabStripClose(item.tab)
    }

    override func mouseExited(with event: NSEvent) {
        guard frozenWidth != nil else { return }
        frozenWidth = nil
        layoutTabs(animated: true)
    }

    // MARK: Dragging

    /// Selects on mouse down (as Chrome), then follows the pointer: sideways reorders, far up or down
    /// (with more than one tab) tears the tab off into its own window.
    func beginDrag(_ item: TabItemView, with event: NSEvent) {
        guard let window else { return }
        delegate?.tabStripSelect(item.tab)
        let start = convert(event.locationInWindow, from: nil)
        let startX = item.frame.minX
        var moved = false
        var detaching = false

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp { break }
            let dx = point.x - start.x
            if !moved && abs(dx) < 4 && abs(point.y - start.y) < 4 { continue }
            if !moved {
                moved = true
                dragging = item
                item.layer?.zPosition = 10
                frozenWidth = nil
            }
            detaching = items.count > 1 && (point.y < -30 || point.y > bounds.height + 30)
            item.alphaValue = detaching ? 0.55 : 1

            let minX = items.filter(\.tab.isPinned).count > 0 && !item.tab.isPinned
                ? (items.last { $0.tab.isPinned }?.frame.maxX ?? tabsStart) + 2 : tabsStart
            let maxX = max(minX, (frames().last?.maxX ?? tabsStart) - item.frame.width)
            item.frame.origin.x = min(max(startX + dx, minX), maxX)

            // Reorder when the dragged tab's centre passes another tab's centre.
            if let from = items.firstIndex(of: item) {
                let center = item.frame.midX
                let rects = frames()
                var to = from
                for (index, rect) in rects.enumerated() where items[index].tab.isPinned == item.tab.isPinned {
                    if index < from, center < rect.midX { to = min(to, index) }
                    if index > from, center > rect.midX { to = max(to, index) }
                }
                if to != from {
                    items.remove(at: from)
                    items.insert(item, at: to)
                    delegate?.tabStripMove(item.tab, to: to)
                    layoutTabs(animated: true)
                }
            }
            needsDisplay = true
        }

        dragging = nil
        item.layer?.zPosition = 0
        item.alphaValue = 1
        if detaching, let screenPoint = window.convertPoint(toScreen: window.mouseLocationOutsideOfEventStream) as NSPoint? {
            delegate?.tabStripDetach(item.tab, at: screenPoint)
        }
        layoutTabs(animated: true)
    }
}

/// One tab in the strip.
final class TabItemView: NSView {
    let tab: BrowserTab
    private weak var strip: TabStripView?

    private let glass = NSGlassEffectView()
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleField = NSTextField(labelWithString: "")
    private let titleMask = CAGradientLayer()
    private let closeButton: IconButton
    private let audioButton: IconButton

    var isActive = false { didSet { if oldValue != isActive { refresh() } } }
    private(set) var isHovering = false

    init(tab: BrowserTab, strip: TabStripView) {
        self.tab = tab
        self.strip = strip
        closeButton = IconButton(symbol: "xmark", label: "Close Tab", target: nil, action: nil)
        audioButton = IconButton(symbol: "speaker.wave.2.fill", label: "Mute Tab", target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous

        glass.cornerRadius = 10
        glass.isHidden = true
        addSubview(glass)

        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)

        titleField.font = .systemFont(ofSize: 12.5)
        titleField.lineBreakMode = .byClipping
        titleField.cell?.truncatesLastVisibleLine = false
        titleField.wantsLayer = true
        titleMask.startPoint = CGPoint(x: 0, y: 0.5)
        titleMask.endPoint = CGPoint(x: 1, y: 0.5)
        titleMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        titleField.layer?.mask = titleMask
        addSubview(titleField)

        closeButton.pointSize = 9
        closeButton.weight = .bold
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        addSubview(closeButton)

        audioButton.pointSize = 10
        audioButton.target = self
        audioButton.action = #selector(toggleMute)
        addSubview(audioButton)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        setAccessibilityRole(.radioButton)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeTab() { strip?.closeClicked(self) }
    @objc private func toggleMute() {
        if tab.isCapturing {
            tab.setCapture(microphone: tab.microphoneState == .muted ? .active : .muted)
        } else {
            strip?.delegate?.tabStripToggleMute(tab)
        }
    }

    func refresh() {
        titleField.stringValue = tab.title
        titleField.textColor = isActive ? .labelColor : .secondaryLabelColor
        titleField.font = .systemFont(ofSize: 12.5, weight: isActive ? .medium : .regular)
        toolTip = tab.title
        setAccessibilityLabel(tab.title)
        setAccessibilityValue(isActive)

        glass.isHidden = !isActive
        layer?.backgroundColor = (!isActive && isHovering) ? NSColor.labelColor.withAlphaComponent(0.06).cgColor : nil

        if tab.isLoading && !tab.isAsleep {
            spinner.startAnimation(nil)
            icon.isHidden = true
        } else {
            spinner.stopAnimation(nil)
            icon.isHidden = false
        }
        icon.image = tab.isNewTabPage
            ? NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: nil)
            : tab.favicon ?? NSImage.monogram(for: tab.url?.host)
        icon.contentTintColor = tab.isNewTabPage ? .secondaryLabelColor : nil
        icon.alphaValue = tab.isAsleep ? 0.45 : 1

        if tab.isCapturing {
            // Camera / microphone in use: a red icon (a click mutes or unmutes the microphone).
            audioButton.isHidden = false
            audioButton.symbol = tab.cameraState == .active ? "video.fill" : tab.microphoneState == .muted ? "mic.slash.fill" : "mic.fill"
            audioButton.contentTintColor = .systemRed
            audioButton.setAccessibilityLabel("Camera or microphone in use")
        } else {
            audioButton.isHidden = !(tab.isPlayingAudio || tab.isMuted)
            audioButton.symbol = tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            audioButton.contentTintColor = nil
            audioButton.setAccessibilityLabel(tab.isMuted ? "Unmute Tab" : "Mute Tab")
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let h = bounds.height
        let compact = bounds.width < 64 || tab.isPinned
        let showClose = !tab.isPinned && (isActive || (isHovering && !compact))
        closeButton.isHidden = !showClose
        let iconRect: NSRect
        if compact {
            // Icon-only: centred; a selected narrow tab shows ✕ in its place.
            iconRect = NSRect(x: (bounds.width - 16) / 2, y: (h - 16) / 2, width: 16, height: 16)
            if showClose {
                closeButton.frame = NSRect(x: (bounds.width - 20) / 2, y: (h - 20) / 2, width: 20, height: 20)
                icon.isHidden = true
                spinner.isHidden = true
            } else {
                spinner.isHidden = false
            }
            titleField.isHidden = true
            audioButton.isHidden = true
        } else {
            iconRect = NSRect(x: 11, y: (h - 16) / 2, width: 16, height: 16)
            spinner.isHidden = false
            icon.isHidden = tab.isLoading && !tab.isAsleep   // the compact branch may have hidden it for ✕
            titleField.isHidden = false
            var right = bounds.width - 6
            closeButton.frame = NSRect(x: right - 20, y: (h - 20) / 2, width: 20, height: 20)
            if showClose { right -= 22 }
            if !audioButton.isHidden {
                audioButton.frame = NSRect(x: right - 20, y: (h - 20) / 2, width: 20, height: 20)
                right -= 22
            }
            let titleX = iconRect.maxX + 7
            titleField.frame = NSRect(x: titleX, y: (h - 16) / 2 - 1, width: max(0, right - titleX), height: 17)
            let w = max(1, titleField.bounds.width)
            let fade = min(1, 18 / w)
            titleMask.frame = titleField.bounds
            titleMask.locations = [0, NSNumber(value: 1 - fade), 1]
        }
        icon.frame = iconRect
        spinner.frame = iconRect
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        refresh()
        strip?.needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        refresh()
        strip?.needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { return }
        strip?.beginDrag(self, with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        // Middle-click closes, as in every browser.
        if event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) {
            strip?.closeClicked(self)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        strip?.delegate?.tabStripMenu(for: tab)
    }

    override var mouseDownCanMoveWindow: Bool { false }
}
