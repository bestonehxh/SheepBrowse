import AppKit
import UniformTypeIdentifiers
import WebKit

/// Downloads go straight to ~/Downloads (as in Chrome), under a name that does not overwrite anything.
/// A file is written under a temporary name and moved into place only when complete.
final class DownloadManager: NSObject {
    static let shared = DownloadManager()
    static let didChange = Notification.Name("SheepBrowseDownloadsDidChange")

    final class Item {
        let id: UUID
        var filename: String
        var destination: URL?
        var temporary: URL?
        var progress: Progress?
        var state: State = .running
        /// Where the file came from (for "Copy Link").
        var sourceURL: URL?
        var date = Date()
        var size: Int64?
        /// From a private window: listed while the app runs, never written to downloads.json.
        var isPrivate = false
        weak var download: WKDownload?
        var observation: NSKeyValueObservation?

        enum State: String, Codable { case running, finished, failed, cancelled }

        init(filename: String) {
            id = UUID()
            self.filename = filename
        }

        init(record: Record) {
            id = record.id
            filename = record.filename
            destination = record.path.map { URL(fileURLWithPath: $0) }
            sourceURL = record.source.flatMap(URL.init(string:))
            date = record.date
            size = record.size
            state = record.state == .running ? .failed : record.state
        }

        var record: Record {
            Record(id: id, filename: filename, path: destination?.path, source: sourceURL?.absoluteString, date: date,
                   size: size, state: state)
        }

        /// A finished file that is no longer where it was saved (Chrome's "Deleted").
        var isMissing: Bool {
            guard state == .finished, let destination else { return false }
            return !FileManager.default.fileExists(atPath: destination.path)
        }

        var fraction: Double { progress?.fractionCompleted ?? 0 }
    }

    /// What downloads.json keeps (the download history).
    struct Record: Codable {
        var id: UUID
        var filename: String
        var path: String?
        var source: String?
        var date: Date
        var size: Int64?
        var state: Item.State
    }

    override init() {
        super.init()
        items = (AppFiles.read([Record].self, from: "downloads.json") ?? []).map(Item.init(record:))
    }

    func remove(_ item: Item) {
        if item.state == .running { cancel(item) }
        items.removeAll { $0 === item }
        changed()
    }

    func clearAll() {
        items.removeAll { $0.state != .running }
        changed()
    }

    private var saveScheduled = false

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            saveScheduled = false
            AppFiles.write(items.filter { $0.state != .running && !$0.isPrivate }.prefix(500).map(\.record), to: "downloads.json")
        }
    }

    private(set) var items: [Item] = []
    private var byDownload: [ObjectIdentifier: Item] = [:]

    var activeCount: Int { items.filter { $0.state == .running }.count }

    /// Overall progress of the running downloads (nil when none run).
    var overallFraction: Double? {
        let running = items.filter { $0.state == .running }
        guard !running.isEmpty else { return nil }
        return running.map(\.fraction).reduce(0, +) / Double(running.count)
    }

    func track(_ download: WKDownload, window: NSWindow?, isPrivate: Bool = false) {
        download.delegate = self
        let item = Item(filename: "Download")
        item.isPrivate = isPrivate
        item.download = download
        item.sourceURL = download.originalRequest?.url
        item.progress = download.progress
        item.observation = download.progress.observe(\.fractionCompleted) { _, _ in
            DispatchQueue.main.async { DownloadManager.shared.changed() }
        }
        byDownload[ObjectIdentifier(download)] = item
        items.insert(item, at: 0)
        changed()
    }

    /// WebKit does not call didFail for a cancel it was asked for: clean up here (the temporary file, the
    /// bookkeeping) or "name.download" stays in ~/Downloads.
    func cancel(_ item: Item) {
        if let download = item.download { byDownload[ObjectIdentifier(download)] = nil }
        item.download?.cancel { _ in }
        item.observation = nil
        if let temporary = item.temporary { try? FileManager.default.removeItem(at: temporary) }
        item.state = .cancelled
        changed()
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
        changed()
    }

    fileprivate func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
        scheduleSave()
    }

    private static func uniqueDestination(for suggested: String) -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let clean = suggested.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let name = clean.isEmpty ? "Download" : clean
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path)
                || FileManager.default.fileExists(atPath: candidate.path + ".download") {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }
}

extension DownloadManager: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        guard let item = byDownload[ObjectIdentifier(download)] else { return nil }
        let destination = Self.uniqueDestination(for: suggestedFilename)
        let temporary = URL(fileURLWithPath: destination.path + ".download")
        item.filename = destination.lastPathComponent
        item.destination = destination
        item.temporary = temporary
        changed()
        return temporary
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = byDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.observation = nil
        if let temporary = item.temporary, let destination = item.destination {
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
                item.state = .finished
                item.size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init)
                // Bounce the Downloads stack in the Dock, as Safari does.
                DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"),
                                                             object: destination.path)
            } catch {
                item.state = .failed
            }
        }
        changed()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = byDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.observation = nil
        if let temporary = item.temporary { try? FileManager.default.removeItem(at: temporary) }
        if item.state != .cancelled { item.state = .failed }
        changed()
    }
}

// MARK: - The list shown from the toolbar

final class DownloadsViewController: NSViewController {
    private let stack = NSStackView()
    private var observer: NSObjectProtocol?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 60))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 340),
        ])
        view = root
        rebuild()
        observer = NotificationCenter.default.addObserver(forName: DownloadManager.didChange, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let header = NSTextField(labelWithString: "Downloads")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(8, after: header)
        let items = DownloadManager.shared.items.prefix(12)
        if items.isEmpty {
            let empty = NSTextField(labelWithString: "Nothing downloaded yet")
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
        }
        for item in items {
            let row = DownloadRow(item: item)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
        let all = NSButton(title: "Show All Downloads", target: self, action: #selector(showAll))
        all.bezelStyle = .glass
        all.controlSize = .small
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(all)
    }

    @objc private func showAll() {
        view.window?.performClose(nil)
        BrowserWindowController.frontmost?.showPage(.downloads)
    }
}

private final class DownloadRow: NSView {
    let item: DownloadManager.Item

    init(item: DownloadManager.Item) {
        self.item = item
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        let icon = NSImageView(image: item.destination.map { NSWorkspace.shared.icon(forFile: $0.path) }
                               ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)!)
        if let ext = item.destination?.pathExtension, item.state != .finished {
            icon.image = NSWorkspace.shared.icon(for: .init(filenameExtension: ext) ?? .data)
        }
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: item.filename)
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: 12, weight: .medium)
        let status = NSTextField(labelWithString: statusText)
        status.font = .systemFont(ofSize: 11)
        status.textColor = item.state == .failed ? .systemRed : .secondaryLabelColor
        let texts = NSStackView(views: [name, status])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        texts.translatesAutoresizingMaskIntoConstraints = false

        let action = NSButton(image: NSImage(systemSymbolName: item.state == .running ? "xmark.circle.fill" : "magnifyingglass.circle.fill",
                                             accessibilityDescription: item.state == .running ? "Cancel" : "Show in Finder")!,
                              target: self, action: #selector(act))
        action.isBordered = false
        action.contentTintColor = .secondaryLabelColor
        action.translatesAutoresizingMaskIntoConstraints = false
        action.isHidden = item.state == .failed || item.state == .cancelled

        addSubview(icon)
        addSubview(texts)
        addSubview(action)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            texts.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -6),
            action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            action.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if item.state == .finished {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var statusText: String {
        switch item.state {
        case .running:
            guard let progress = item.progress, progress.totalUnitCount > 0 else { return "Starting…" }
            let done = ByteCountFormatter.string(fromByteCount: progress.completedUnitCount, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: progress.totalUnitCount, countStyle: .file)
            return "\(done) of \(total)"
        case .finished:
            let size = (try? item.destination?.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
            return size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }

    override func mouseUp(with event: NSEvent) {
        guard item.state == .finished, let destination = item.destination, event.clickCount >= 1 else { return }
        NSWorkspace.shared.open(destination)
    }

    @objc private func act() {
        if item.state == .running {
            DownloadManager.shared.cancel(item)
        } else if let destination = item.destination {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }
}
