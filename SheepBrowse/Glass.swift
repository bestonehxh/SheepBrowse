import AppKit

/// A Liquid Glass capsule (or rounded rectangle) that hosts controls. Subviews go into `content`.
class GlassCapsule: NSView {
    let glass = NSGlassEffectView()
    let content = NSView()
    /// nil = a capsule (half the height).
    var radius: CGFloat?

    init(radius: CGFloat? = nil, interactive: Bool = true) {
        self.radius = radius
        super.init(frame: .zero)
        glass.contentView = content
        if #available(macOS 27, *) { glass.effectIsInteractive = interactive }
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = glass.bounds
        glass.cornerRadius = radius ?? bounds.height / 2
    }
}

/// A borderless icon button with the soft hover/pressed capsule used across the toolbar.
class IconButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    var symbol: String { didSet { updateImage() } }
    var pointSize: CGFloat = 14 { didSet { updateImage() } }
    var weight: NSFont.Weight = .medium { didSet { updateImage() } }
    var onRightClick: ((NSEvent) -> Void)?
    var onLongPress: (() -> Void)?
    private var longPressTimer: Timer?
    private var longPressFired = false

    init(symbol: String, label: String, target: AnyObject?, action: Selector?) {
        self.symbol = symbol
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 28))
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        setAccessibilityLabel(label)
        toolTip = nil
        wantsLayer = true
        updateImage()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateImage() {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel())?
            .withSymbolConfiguration(config)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = isHighlighted
        if (hovering || pressed) && isEnabled {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: bounds.height / 2 - 1,
                                    yRadius: bounds.height / 2 - 1)
            NSColor.labelColor.withAlphaComponent(pressed ? 0.14 : 0.07).setFill()
            path.fill()
        }
        super.draw(dirtyRect)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick { onRightClick(event) } else { super.rightMouseDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let onLongPress, isEnabled else { return super.mouseDown(with: event) }
        longPressFired = false
        isHighlighted = true
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.longPressFired = true
                self?.isHighlighted = false
                self?.onLongPress?()
            }
        }
        // Track until mouse up (or the long press opened its menu).
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if longPressFired { break }
            if next.type == .leftMouseUp {
                longPressTimer?.invalidate()
                isHighlighted = false
                if bounds.contains(convert(next.locationInWindow, from: nil)) { sendAction(action, to: target) }
                break
            }
            isHighlighted = bounds.contains(convert(next.locationInWindow, from: nil))
        }
        longPressTimer?.invalidate()
    }
}

/// A view whose empty parts move the window (title bar behaviour) and zoom it on double-click.
class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window?.performMiniaturize(nil) } else if action != "None" { window?.performZoom(nil) }
            return
        }
        window?.performDrag(with: event)
    }
}

extension NSImage {
    /// A rounded monogram for a site without a favicon.
    static func monogram(for host: String?, size: CGFloat = 32) -> NSImage {
        let letter = String((AddressInput.site(of: host) ?? "?").prefix(1)).uppercased()
        let palette: [NSColor] = [.systemBlue, .systemPurple, .systemPink, .systemOrange, .systemTeal, .systemIndigo, .systemGreen]
        // A stable hash (String.hashValue changes every launch, and so would the colour).
        let color = palette[(host ?? "").unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % palette.count]
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: size * 0.24, yRadius: size * 0.24).fill()
            let font = NSFont.systemFont(ofSize: size * 0.56, weight: .bold)
            let text = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: NSColor.white])
            let textSize = text.size()
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            return true
        }
    }
}

/// A borderless text field for search boxes. NSSearchField draws its own magnifier inside the text area,
/// which overlapped the first letters in a borderless glass box; our boxes draw the icon beside it instead.
final class PlainSearchField: NSTextField {
    convenience init(placeholder: String, size: CGFloat) {
        self.init(frame: .zero)
        placeholderString = placeholder
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: size)
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        translatesAutoresizingMaskIntoConstraints = false
    }
}

/// Magnifier · field · clear button, in a row (inside a glass capsule).
final class SearchRow: NSStackView {
    let field: PlainSearchField
    private let clear = IconButton(symbol: "xmark.circle.fill", label: "Clear", target: nil, action: nil)
    var onClear: (() -> Void)?

    init(placeholder: String, size: CGFloat = 14) {
        field = PlainSearchField(placeholder: placeholder, size: size)
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: size - 1, weight: .medium))!)
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        clear.pointSize = 12
        clear.contentTintColor = .tertiaryLabelColor
        clear.target = self
        clear.action = #selector(clearTapped)
        clear.isHidden = true
        clear.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [icon, field, clear] as [NSView] { addArrangedSubview(view) }
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSControl.textDidChangeNotification, object: field)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func textChanged() { clear.isHidden = field.stringValue.isEmpty }

    /// Call after setting the text in code.
    func refresh() { clear.isHidden = field.stringValue.isEmpty }

    @objc private func clearTapped() {
        field.stringValue = ""
        clear.isHidden = true
        onClear?()
        window?.makeFirstResponder(field)
    }
}
