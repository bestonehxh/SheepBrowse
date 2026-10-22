import AppKit
import WebKit

/// A "Dynamic Island" for the camera and microphone: while any tab captures, a black capsule grows out of
/// the notch (or floats under the menu bar on a Mac without one), on every Space and over full-screen apps.
/// Compact: a pulsing red dot with the camera/mic icons on the left wing, the site on the right. Hovered:
/// it opens into one row per capturing tab with mute / camera / show buttons.
final class CaptureIsland {
    static let shared = CaptureIsland()

    private var panel: IslandPanel?
    private var observer: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    func start() {
        observer = NotificationCenter.default.addObserver(forName: BrowserTab.captureDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CaptureIsland.shared.refresh() }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { _ in
            // A display came or went (lid closed): notch, bar height and place all change — start compact again.
            MainActor.assumeIsolated { CaptureIsland.shared.panel?.screensChanged() }
        }
    }

    #if DEBUG
    func debugExpand() { panel?.debugHover() }
    #endif

    var capturingTabs: [BrowserTab] { BrowserWindowController.all.flatMap(\.tabs).filter(\.isCapturing) }

    func refresh() {
        let tabs = capturingTabs
        guard !tabs.isEmpty else {
            panel?.orderOut(nil)
            panel = nil
            return
        }
        let panel = self.panel ?? IslandPanel()
        self.panel = panel
        panel.update(tabs)
        if !panel.isVisible { panel.appear() }
    }
}

final class IslandPanel: NSPanel {
    private let island = IslandView()
    private var expanded = false
    private var collapseWork: DispatchWorkItem?

    /// The screen with the notch (else the one with the menu bar).
    private var screen0: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first }
    private var notchWidth: CGFloat {
        guard let screen = screen0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return 0 }
        return screen.frame.width - left.width - right.width
    }
    private var hasNotch: Bool { notchWidth > 0 }
    private var barHeight: CGFloat { max(screen0?.safeAreaInsets.top ?? 0, 24) }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = island
        island.onHover = { [weak self] inside in self?.hover(inside) }
    }

    override var canBecomeKey: Bool { false }

    func update(_ tabs: [BrowserTab]) {
        island.notched = hasNotch
        island.notchWidth = notchWidth
        island.barHeight = barHeight
        island.tabs = tabs
        if expanded { placeExpanded(animated: true) } else { placeCompact(animated: isVisible) }
    }

    func screensChanged() {
        collapseWork?.cancel()
        expanded = false
        update(island.tabs)
    }

    func appear() {
        placeCompact(animated: false)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; animator().alphaValue = 1 }
    }

    func placeCompact(animated: Bool) {
        guard let screen = screen0 else { return }
        let width = hasNotch ? notchWidth + 2 * 74 : 210
        let height = hasNotch ? barHeight : 30
        let y = hasNotch ? screen.frame.maxY - height : screen.visibleFrame.maxY - height - 6
        island.expanded = false
        setFrame(NSRect(x: screen.frame.midX - width / 2, y: y, width: width, height: height), display: true, animate: animated)
    }

    private func placeExpanded(animated: Bool) {
        guard let screen = screen0 else { return }
        let width = max(hasNotch ? notchWidth + 2 * 74 : 210, 380)
        let rows = CGFloat(max(1, island.tabs.count))
        // The wings' strip (the notch's height, or 30 pt), then the rows (46 pt, 4 pt apart) with 8 pt above, 10 below.
        let top = hasNotch ? barHeight : 30
        let height = top + 8 + rows * 50 - 4 + 10
        let y = hasNotch ? screen.frame.maxY - height : screen.visibleFrame.maxY - height - 6
        island.expanded = true
        setFrame(NSRect(x: screen.frame.midX - width / 2, y: y, width: width, height: height), display: true, animate: animated)
    }

    #if DEBUG
    func debugHover() { hover(true) }
    #endif

    private func hover(_ inside: Bool) {
        collapseWork?.cancel()
        if inside {
            guard !expanded else { return }
            expanded = true
            placeExpanded(animated: true)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.expanded else { return }
                self.expanded = false
                self.placeCompact(animated: true)
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }
}

final class IslandView: NSView {
    var onHover: ((Bool) -> Void)?
    var notched = true
    var notchWidth: CGFloat = 0
    var barHeight: CGFloat = 32
    var expanded = false { didSet { rebuild() } }
    var tabs: [BrowserTab] = [] { didSet { rebuild() } }

    private let dot = NSView()
    private let leftIcons = NSStackView()
    private let rightIcon = NSImageView()
    private let count = NSTextField(labelWithString: "")
    private let rows = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.35
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")
        leftIcons.spacing = 5
        rightIcon.imageScaling = .scaleProportionallyUpOrDown
        rightIcon.wantsLayer = true
        rightIcon.layer?.cornerRadius = 4
        rightIcon.layer?.masksToBounds = true
        count.font = .systemFont(ofSize: 11, weight: .semibold)
        count.textColor = .white
        rows.orientation = .vertical
        rows.spacing = 4
        rows.alignment = .width
        for view in [dot, leftIcons, rightIcon, count, rows] { addSubview(view) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    /// Black, flush with the top edge (it continues the notch), rounded below — or a full capsule without a notch.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        let radius: CGFloat = expanded ? 22 : (notched ? 12 : bounds.height / 2)
        if notched {
            let path = NSBezierPath()
            let r = min(radius, bounds.height / 2)
            path.move(to: NSPoint(x: 0, y: bounds.maxY))
            path.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY))
            path.line(to: NSPoint(x: bounds.maxX, y: r))
            path.appendArc(withCenter: NSPoint(x: bounds.maxX - r, y: r), radius: r, startAngle: 0, endAngle: 270, clockwise: true)
            path.line(to: NSPoint(x: r, y: 0))
            path.appendArc(withCenter: NSPoint(x: r, y: r), radius: r, startAngle: 270, endAngle: 180, clockwise: true)
            path.close()
            path.fill()
        } else {
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
    }

    private func symbol(_ name: String, _ color: NSColor = .white, size: CGFloat = 11) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))!)
        view.contentTintColor = color
        return view
    }

    private func rebuild() {
        leftIcons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let camera = tabs.contains { $0.cameraState != .none }
        let mic = tabs.contains { $0.microphoneState != .none }
        if camera { leftIcons.addArrangedSubview(symbol("video.fill")) }
        if mic { leftIcons.addArrangedSubview(symbol(tabs.allSatisfy { $0.microphoneState != .active } ? "mic.slash.fill" : "mic.fill")) }
        rightIcon.image = tabs.first?.favicon ?? NSImage.monogram(for: tabs.first?.url?.host)
        count.stringValue = tabs.count > 1 ? "\(tabs.count)" : ""

        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if expanded { for tab in tabs { rows.addArrangedSubview(IslandRow(tab: tab)) } }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let wingHeight = notched ? barHeight : (expanded ? 30 : bounds.height)
        let wingTop = bounds.maxY - wingHeight
        let mid = wingTop + wingHeight / 2
        dot.frame = NSRect(x: 16, y: mid - 4, width: 8, height: 8)
        let iconsSize = leftIcons.fittingSize
        leftIcons.frame = NSRect(x: 30, y: mid - iconsSize.height / 2, width: iconsSize.width, height: iconsSize.height)
        rightIcon.frame = NSRect(x: bounds.maxX - 16 - 16, y: mid - 8, width: 16, height: 16)
        count.sizeToFit()
        count.frame.origin = NSPoint(x: rightIcon.frame.minX - 4 - count.frame.width, y: mid - count.frame.height / 2)
        let listTop = notched ? bounds.maxY - barHeight - 8 : bounds.maxY - 30
        rows.frame = NSRect(x: 12, y: 10, width: bounds.width - 24, height: max(0, listTop - 10))
    }
}

/// One capturing tab in the open island.
private final class IslandRow: NSView {
    private let tab: BrowserTab

    init(tab: BrowserTab) {
        self.tab = tab
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        let icon = NSImageView(image: tab.favicon ?? NSImage.monogram(for: tab.url?.host))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let host = NSTextField(labelWithString: tab.url?.host ?? tab.title)
        host.font = .systemFont(ofSize: 12.5, weight: .semibold)
        host.textColor = .white
        host.lineBreakMode = .byTruncatingTail
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [icon, host, NSView()]
        if tab.microphoneState != .none {
            let muted = tab.microphoneState == .muted
            views.append(circle(muted ? "mic.slash.fill" : "mic.fill", on: !muted) { [weak tab] in
                tab?.setCapture(microphone: muted ? .active : .muted)
            })
        }
        if tab.cameraState != .none {
            let off = tab.cameraState == .muted
            views.append(circle(off ? "video.slash.fill" : "video.fill", on: !off) { [weak tab] in
                tab?.setCapture(camera: off ? .active : .muted)
            })
        }
        views.append(circle("phone.down.fill", on: false, tint: .systemRed) { [weak tab] in
            tab?.setCapture(camera: WKMediaCaptureState.none, microphone: WKMediaCaptureState.none)
        })
        views.append(circle("arrow.up.forward", on: false) { [weak tab] in
            guard let tab else { return }
            BrowserWindowController.reveal(tab)
            NSApp.activate()
        })
        let stack = NSStackView(views: views)
        stack.spacing = 10
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A round control like the island's on iPhone: filled white when on.
    private func circle(_ symbol: String, on: Bool, tint: NSColor? = nil, action: @escaping () -> Void) -> NSView {
        IslandControl(symbol: symbol, on: on, tint: tint, action: action)
    }
}

/// One island button: a 34 pt Liquid Glass circle with a 14 pt semibold symbol — every control the same
/// size and weight. On = white-tinted glass with a dark symbol; off = clear glass; a tint (end) = that colour.
final class IslandControl: NSView {
    static let side: CGFloat = 34
    private let action: () -> Void
    private let glass = NSGlassEffectView()
    private let icon = NSImageView()

    init(symbol: String, on: Bool, tint: NSColor?, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        // Glass over the island's black has nothing to bend: a colour disc under it carries the state,
        // the glass on top gives it the lens, the rim and the press response.
        wantsLayer = true
        let disc = CALayer()
        disc.frame = bounds
        disc.cornerRadius = Self.side / 2
        disc.backgroundColor = (tint ?? (on ? NSColor.white.withAlphaComponent(0.92) : NSColor.white.withAlphaComponent(0.14))).cgColor
        layer?.addSublayer(disc)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        glass.cornerRadius = Self.side / 2
        glass.style = .clear
        if #available(macOS 27, *) { glass.effectIsInteractive = true }
        let content = NSView(frame: bounds)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        icon.contentTintColor = on && tint == nil ? .black : .white
        icon.imageScaling = .scaleNone
        icon.frame = content.bounds
        icon.autoresizingMask = [.width, .height]
        content.addSubview(icon)
        glass.contentView = content
        addSubview(glass)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    // The glass reacts to the press itself (interactive glass); the action fires on release inside.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}
