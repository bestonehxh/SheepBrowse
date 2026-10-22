import AppKit
import UniformTypeIdentifiers

/// The Passwords window, laid out like Apple's Passwords app: a searchable list of sites on the left,
/// the selected login on the right (big icon, user name, password hidden until Touch ID, copy buttons).
final class PasswordsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let shared = PasswordsWindowController()

    private let table = NSTableView()
    private let search = NSSearchField()
    private let detail = PasswordDetailView()
    private let emptyLabel = NSTextField(labelWithString: "No Saved Passwords")
    private var rows: [SavedPassword] = []
    private var observer: NSObjectProtocol?
    private var unlockedAt: Date?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "Passwords"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 620, height: 380)
        window.center()
        window.setFrameAutosaveName("PasswordsWindow")
        super.init(window: window)
        build()
        observer = NotificationCenter.default.addObserver(forName: PasswordStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        // Closing the window locks it again: the next open asks for Touch ID.
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.detail.unlocked = false }
        }
    }

    private var closeObserver: NSObjectProtocol?

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let window else { return }
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin

        // Sidebar: search + list + import.
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        search.placeholderString = "Search"
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: .init("site"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 44
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Copy User Name") { [weak self] in self?.detail.copyUser() })
        menu.addItem(ClosureMenuItem(title: "Copy Password") { [weak self] in self?.detail.copyPassword() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Delete…") { [weak self] in self?.deleteSelected() })
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let importButton = NSButton(title: "Import…", image: NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)!,
                                    target: self, action: #selector(importCSV))
        importButton.bezelStyle = .glass
        importButton.controlSize = .small
        importButton.translatesAutoresizingMaskIntoConstraints = false
        for view in [search, scroll, importButton] as [NSView] { sidebar.addSubview(view) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 44),
            search.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: importButton.topAnchor, constant: -8),
            importButton.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            importButton.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -12),
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 230),
            sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])

        let right = NSView()
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.onDelete = { [weak self] in self?.deleteSelected() }
        emptyLabel.font = .systemFont(ofSize: 17, weight: .medium)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(detail)
        right.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            detail.topAnchor.constraint(equalTo: right.topAnchor, constant: 54),
            detail.centerXAnchor.constraint(equalTo: right.centerXAnchor),
            detail.widthAnchor.constraint(equalTo: right.widthAnchor, multiplier: 0.82),
            emptyLabel.centerXAnchor.constraint(equalTo: right.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: right.centerYAnchor),
        ])

        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(right)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        window.contentView = split
        split.setPosition(270, ofDividerAt: 0)
    }

    override func showWindow(_ sender: Any?) {
        Task { @MainActor in
            guard await PasswordStore.shared.authenticate(reason: "show your saved passwords") else { return }
            unlockedAt = Date()
            detail.unlocked = true
            reload()
            super.showWindow(sender)
            window?.makeKeyAndOrderFront(sender)
        }
    }

    func reload() {
        let selectedID = table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow].id : nil
        let needle = search.stringValue.lowercased()
        rows = PasswordStore.shared.all
            .filter { needle.isEmpty || $0.host.lowercased().contains(needle) || $0.username.lowercased().contains(needle) }
            .sorted { (AddressInput.site(of: $0.host) ?? $0.host, $0.username) < (AddressInput.site(of: $1.host) ?? $1.host, $1.username) }
        table.reloadData()
        let index = rows.firstIndex { $0.id == selectedID } ?? (rows.isEmpty ? nil : 0)
        if let index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        showSelection()
    }

    private func showSelection() {
        let row = table.selectedRow
        let entry = row >= 0 && row < rows.count ? rows[row] : nil
        detail.isHidden = entry == nil
        emptyLabel.isHidden = entry != nil
        emptyLabel.stringValue = PasswordStore.shared.all.isEmpty ? "No Saved Passwords" : "No Results"
        if let entry { detail.show(entry) }
    }

    func controlTextDidChange(_ obj: Notification) { reload() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { showSelection() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[row]
        let icon = SiteIconView(host: entry.host, size: 28)
        let title = NSTextField(labelWithString: AddressInput.site(of: entry.host) ?? entry.host)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let user = NSTextField(labelWithString: entry.username.isEmpty ? "No user name" : entry.username)
        user.font = .systemFont(ofSize: 11.5)
        user.textColor = .secondaryLabelColor
        user.lineBreakMode = .byTruncatingTail
        let texts = NSStackView(views: [title, user]).vertical()
        texts.spacing = 1
        let stack = NSStackView(views: [icon, texts])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        return stack
    }

    private func deleteSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < rows.count, let window else { return }
        let entry = rows[row]
        let alert = NSAlert()
        alert.messageText = "Delete the password for \(entry.host)?"
        alert.informativeText = entry.username.isEmpty ? "" : entry.username
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { PasswordStore.shared.delete([entry.id]) }
        }
    }

    @objc private func importCSV() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Choose a passwords CSV exported from Chrome (Settings ▸ Passwords ▸ Export) or the Passwords app (File ▸ Export)."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let count = PasswordStore.shared.importCSV(text)
            let alert = NSAlert()
            alert.messageText = count > 0 ? "Imported \(count) passwords" : "No passwords found in that file"
            alert.informativeText = count > 0 ? "Delete the CSV file now — it holds your passwords in plain text." : ""
            alert.beginSheetModal(for: window)
        }
    }
}

/// A site icon in a rounded tile (the favicon, or a coloured letter).
final class SiteIconView: NSView {
    init(host: String, size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.cornerRadius = size * 0.26
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.masksToBounds = true
        let favicon = FaviconCache.shared.image(for: host)
        let image = NSImageView(image: favicon ?? NSImage.monogram(for: host, size: size))
        image.imageScaling = .scaleProportionallyUpOrDown
        image.frame = favicon == nil ? bounds : bounds.insetBy(dx: size * 0.18, dy: size * 0.18)
        addSubview(image)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// The right side: one login.
final class PasswordDetailView: NSView {
    var onDelete: (() -> Void)?
    var unlocked = false
    private var entry: SavedPassword?
    private var revealed = false
    private let header = NSStackView()
    private let card = GlassCapsule(radius: 14, interactive: false)
    private let userValue = NSTextField(labelWithString: "")
    private let passValue = NSTextField(labelWithString: "")
    private let siteValue = NSButton(title: "", target: nil, action: nil)
    private let footnote = NSTextField(labelWithString: "")
    private let revealButton = IconButton(symbol: "eye", label: "Show Password", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        header.orientation = .horizontal
        header.spacing = 14
        header.alignment = .centerY

        userValue.isSelectable = true
        userValue.font = .systemFont(ofSize: 13)
        passValue.font = .systemFont(ofSize: 13)
        siteValue.isBordered = false
        siteValue.contentTintColor = .linkColor
        siteValue.target = self
        siteValue.action = #selector(openSite)
        revealButton.target = self
        revealButton.action = #selector(toggleReveal)
        revealButton.pointSize = 12

        let rows = NSStackView(views: [
            row("User Name", userValue, copy: #selector(copyUserTapped)),
            separator(),
            row("Password", passValue, copy: #selector(copyPasswordTapped), extra: revealButton),
            separator(),
            row("Website", siteValue, copy: nil),
        ])
        rows.orientation = .vertical
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        card.content.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: card.content.topAnchor, constant: 4),
            rows.bottomAnchor.constraint(equalTo: card.content.bottomAnchor, constant: -4),
            rows.leadingAnchor.constraint(equalTo: card.content.leadingAnchor, constant: 14),
            rows.trailingAnchor.constraint(equalTo: card.content.trailingAnchor, constant: -10),
        ])

        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .tertiaryLabelColor
        let delete = NSButton(title: "Delete Password", target: self, action: #selector(deleteTapped))
        delete.bezelStyle = .glass
        delete.contentTintColor = .systemRed

        let stack = NSStackView(views: [header, card, footnote, delete])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.setCustomSpacing(10, after: card)
        stack.setCustomSpacing(26, after: footnote)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func row(_ label: String, _ value: NSView, copy: Selector?, extra: NSView? = nil) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 13)
        title.textColor = .secondaryLabelColor
        title.widthAnchor.constraint(equalToConstant: 92).isActive = true
        var views: [NSView] = [title, value, NSView()]
        if let extra { views.append(extra) }
        if let copy {
            let button = IconButton(symbol: "doc.on.doc", label: "Copy \(label)", target: self, action: copy)
            button.pointSize = 12
            views.append(button)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return stack
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    func show(_ entry: SavedPassword) {
        if self.entry?.id != entry.id { revealed = false }
        self.entry = entry
        header.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let title = NSTextField(labelWithString: AddressInput.site(of: entry.host) ?? entry.host)
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let sub = NSTextField(labelWithString: entry.host)
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        header.addArrangedSubview(SiteIconView(host: entry.host, size: 56))
        header.addArrangedSubview(NSStackView(views: [title, sub]).vertical())

        userValue.stringValue = entry.username.isEmpty ? "—" : entry.username
        passValue.stringValue = revealed ? entry.password : String(repeating: "•", count: 12)
        passValue.font = revealed ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 13)
        passValue.isSelectable = revealed
        revealButton.symbol = revealed ? "eye.slash" : "eye"
        siteValue.title = entry.host
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        footnote.stringValue = "Saved \(formatter.string(from: entry.created))" +
            (entry.lastUsed.map { " · Last used \(formatter.string(from: $0))" } ?? "")
    }

    @objc private func toggleReveal() {
        Task { @MainActor in
            var allowed = revealed || unlocked
            if !allowed { allowed = await PasswordStore.shared.authenticate(reason: "show a password") }
            guard allowed else { return }
            revealed.toggle()
            if let entry { show(entry) }
        }
    }

    @objc private func copyUserTapped() { copyUser() }
    @objc private func copyPasswordTapped() { copyPassword() }

    func copyUser() {
        guard let entry else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.username, forType: .string)
    }

    func copyPassword() {
        guard let entry else { return }
        Task { @MainActor in
            var allowed = unlocked
            if !allowed { allowed = await PasswordStore.shared.authenticate(reason: "copy a password") }
            guard allowed else { return }
            NSPasteboard.general.clearContents()
            // Marked concealed so clipboard managers skip it.
            NSPasteboard.general.setString(entry.password, forType: .string)
            NSPasteboard.general.setString("", forType: .init("org.nspasteboard.ConcealedType"))
        }
    }

    @objc private func openSite() {
        guard let entry, let url = URL(string: "https://\(entry.host)") else { return }
        (BrowserWindowController.frontmost ?? BrowserWindowController.newWindow())?.open(url, typed: false, disposition: .newTab)
    }

    @objc private func deleteTapped() { onDelete?() }
}
