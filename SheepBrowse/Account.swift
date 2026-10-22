import AppKit
import Observation
import SheepSync
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The Google account signed in on the web (the browser's own cookies), for the avatar at the top right.
/// Read the way a person sees it: a hidden web view (same data store, so the same sign-in) opens
/// google.com and reads its account button ("Google Account: Name (email)" + the photo). It runs only
/// when the sign-in cookie changes (sign in, sign out, switch), not on every cookie Google updates.
final class GoogleAccount: NSObject, WKNavigationDelegate {
    static let shared = GoogleAccount()
    static let didChange = Notification.Name("SheepBrowseGoogleAccountDidChange")

    struct Info: Equatable {
        var name: String
        var email: String
        var photoURL: URL?
    }

    private(set) var account: Info?
    private(set) var photo: NSImage?

    private var refreshScheduled = false
    private var observing = false
    /// A digest of the sign-in cookie last read: unchanged = nothing to do.
    private var lastSession: Int?
    private var probe: WKWebView?
    private var probeTimeout: DispatchWorkItem?

    func start() {
        if !observing {
            observing = true
            WKWebsiteDataStore.default().httpCookieStore.add(self)
        }
        refresh(force: true)
    }

    /// Coalesces bursts (a sign-in sets dozens of cookies).
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh(force: false)
        }
    }

    func refresh(force: Bool) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            MainActor.assumeIsolated {
                guard let self else { return }
                let session = cookies.filter {
                    ($0.domain == ".google.com" || $0.domain == "google.com") && ["SID", "__Secure-1PSID", "__Secure-3PSID"].contains($0.name)
                }
                guard !session.isEmpty else {
                    self.lastSession = nil
                    self.update(nil)
                    return
                }
                let digest = session.map { $0.name + "=" + $0.value }.sorted().joined().hashValue
                guard force || digest != self.lastSession || self.account == nil else { return }
                self.lastSession = digest
                self.readAccountFromGoogle()
            }
        }
    }

    /// A sign-in change arrived while a probe was reading with the old cookies: read again when it ends.
    private var probeAgain = false

    private func readAccountFromGoogle() {
        guard probe == nil else { probeAgain = true; return }
        guard let url = URL(string: "https://www.google.com/") else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = WebEngine.shared.applicationNameForUserAgent
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: config)
        view.navigationDelegate = self
        probe = view
        view.load(URLRequest(url: url))
        // A page that never finishes must not keep a web process alive.
        let timeout = DispatchWorkItem { [weak self] in self?.finishProbe(nil, keep: true) }
        probeTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === probe else { return }
        let script = """
        const labelled = [...document.querySelectorAll('[aria-label]')]
          .filter(e => /\\([^()\\s]+@[^()\\s]+\\)/.test(e.getAttribute('aria-label') || ''));
        if (!labelled.length) return null;
        // Prefer the account button that holds the photo; any profile photo on the page also counts.
        const a = labelled.find(e => e.querySelector('img')) || labelled[0];
        const imgs = [...a.querySelectorAll('img'), ...document.querySelectorAll('img[src*="googleusercontent.com"], img[srcset*="googleusercontent.com"]')];
        const urls = imgs.flatMap(i => [i.currentSrc, i.src, i.getAttribute('data-src'), i.getAttribute('srcset')]).filter(Boolean).join(' ');
        return [a.getAttribute('aria-label'), urls];
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard case .success(let value) = result, let parts = value as? [String], parts.count == 2 else {
                    self?.finishProbe(nil)
                    return
                }
                let info = Self.parse(label: parts[0], photo: parts[1])
                // Diagnostics without personal data: whether a photo URL was found, and from which hosts.
                let hosts = Set(parts[1].split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { URL(string: String($0))?.host })
                NSLog("SheepBrowse account probe: account=%@ photo=%@ candidateHosts=%@", info == nil ? "no" : "yes",
                      info?.photoURL == nil ? "no" : "yes", hosts.sorted().joined(separator: ","))
                self?.finishProbe(info)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishProbe(nil, keep: true) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishProbe(nil, keep: true)
    }

    /// "Google Account: Sarawut C (name@gmail.com)" in any language → name + email.
    static func parse(label: String, photo: String) -> Info? {
        guard let open = label.lastIndex(of: "("), let close = label.lastIndex(of: ")"), open < close else { return nil }
        let email = String(label[label.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        guard email.contains("@") else { return nil }
        var name = String(label[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = name.lastIndex(where: { $0 == ":" || $0 == "：" }) {
            name = String(name[name.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        // Only a real profile photo (googleusercontent.com), never a placeholder or a data: URL.
        let photoURL = photo.split(whereSeparator: { $0 == " " || $0 == "," }).lazy
            .compactMap { URL(string: String($0)) }
            .first { $0.scheme == "https" && ($0.host ?? "").hasSuffix("googleusercontent.com") }
        return Info(name: name.isEmpty ? email : name, email: email, photoURL: photoURL)
    }

    /// `keep`: a network failure says nothing about the account — the last one stays.
    private func finishProbe(_ info: Info?, keep: Bool = false) {
        probeTimeout?.cancel()
        probeTimeout = nil
        probe?.navigationDelegate = nil
        probe?.stopLoading()
        probe = nil
        if probeAgain {
            probeAgain = false
            return readAccountFromGoogle()
        }
        if keep {
            lastSession = nil
            return
        }
        update(info)
    }

    private func update(_ info: Info?) {
        guard info != account || (info != nil && photo == nil) else { return }
        account = info
        photo = nil
        NotificationCenter.default.post(name: Self.didChange, object: self)
        guard let url = info?.photoURL else { return }
        // A sharper avatar than the 32–64 px on google.com.
        var text = url.absoluteString
        if let range = text.range(of: #"=s\d+(-[^/?#]*)?"#, options: .regularExpression) { text.replaceSubrange(range, with: "=s128-c") }
        URLSession.shared.dataTask(with: URL(string: text) ?? url) { data, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let data, let image = NSImage(data: data), image.size.width > 4,
                          GoogleAccount.shared.account == info else { return }
                    GoogleAccount.shared.photo = image
                    NotificationCenter.default.post(name: GoogleAccount.didChange, object: GoogleAccount.shared)
                }
            }
        }.resume()
    }
}

extension GoogleAccount: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { GoogleAccount.shared.scheduleRefresh() }
        }
    }
}

// MARK: - The button at the top right of the tab row

/// As in SheepTerm: "Sign in" until there is an account (Sync's or the web's); then the chosen picture in a
/// glass circle with Sync's status ring around it. A click opens the account card.
final class AccountButton: NSView {
    var onSignIn: (() -> Void)?
    var onOpen: ((URL) -> Void)?
    private let pill = GlassCapsule(radius: nil, interactive: true)
    private let label = NSTextField(labelWithString: "Sign in")
    private let circle = GlassCapsule(radius: nil, interactive: true)
    private let avatar = NSImageView()
    private let ring = CAShapeLayer()
    private var observers: [NSObjectProtocol] = []
    private var popover: NSPopover?

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let icon = NSImageView(image: NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))!)
        icon.contentTintColor = .controlAccentColor
        let row = NSStackView(views: [icon, label])
        row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false
        pill.content.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: pill.content.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: pill.content.centerYAnchor),
        ])
        avatar.imageScaling = .scaleProportionallyUpOrDown
        circle.content.addSubview(avatar)
        circle.content.wantsLayer = true
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.lineCap = .round
        circle.content.layer?.addSublayer(ring)
        addSubview(pill)
        addSubview(circle)
        setAccessibilityRole(.button)
        for name in [GoogleAccount.didChange, AccountAvatar.didChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        trackSync()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Re-reads Sync's state whenever the engine's observed values change.
    private func trackSync() {
        let engine = SyncController.shared.engine
        withObservationTracking {
            _ = engine.phase; _ = engine.isSyncing; _ = engine.isOnline; _ = engine.lastError; _ = engine.account
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.refresh()
                    self?.trackSync()
                }
            }
        }
    }

    static var hasAccount: Bool { GoogleAccount.shared.account != nil || SyncRing.isSignedIn }

    /// Width the tab row must leave free.
    var preferredWidth: CGFloat { Self.hasAccount ? 28 : 84 }

    func refresh() {
        let signedIn = Self.hasAccount
        pill.isHidden = signedIn
        circle.isHidden = !signedIn
        avatar.image = AccountAvatar.shared.image(side: 44)
        let state = SyncRing.state
        ring.strokeColor = state.nsColor.cgColor
        ring.isHidden = state == .none
        ring.removeAnimation(forKey: "spin")
        if state == .syncing {
            ring.strokeEnd = 0.3
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 1.2
            spin.repeatCount = .infinity
            ring.add(spin, forKey: "spin")
        } else {
            ring.strokeEnd = 1
        }
        let name = SyncController.shared.engine.account ?? GoogleAccount.shared.account?.email
        toolTip = signedIn ? (name ?? "Account") : "Sign in"
        setAccessibilityLabel(toolTip ?? "")
        superview?.needsLayout = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        pill.frame = bounds
        let side = min(bounds.width, bounds.height)
        circle.frame = NSRect(x: bounds.width - side, y: (bounds.height - side) / 2, width: side, height: side)
        let inset: CGFloat = ring.isHidden ? 3 : 5
        avatar.frame = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
        let ringRect = NSRect(x: 2, y: 2, width: side - 4, height: side - 4)
        ring.frame = ringRect
        ring.bounds = NSRect(origin: .zero, size: ringRect.size)
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ring.position = CGPoint(x: ringRect.midX, y: ringRect.midY)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if let popover, popover.isShown { return popover.performClose(nil) }
        let card = NSPopover()
        card.behavior = .transient
        let hosting = NSHostingController(rootView: AccountCard())
        // The card grows when the pictures or the passphrase field open.
        hosting.sizingOptions = [.preferredContentSize]
        card.contentViewController = hosting
        card.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        popover = card
    }
}

/// Sync's state as the ring around the avatar (SheepTerm's `SyncRingState`): green = synced, a turning green
/// arc = syncing, orange = needs the user (passphrase, an error), red = offline. No ring = Sync is off.
enum SyncRing: Equatable {
    case none, synced, syncing, attention, offline

    static var isSignedIn: Bool {
        switch SyncController.shared.engine.phase {
        case .notConfigured, .signedOut, .signingIn: false
        default: true
        }
    }

    static var state: SyncRing {
        let engine = SyncController.shared.engine
        switch engine.phase {
        case .notConfigured, .signedOut, .signingIn: return .none
        case .checkingVault:
            if !engine.isOnline { return .offline }
            return engine.lastError == nil ? .syncing : .attention
        case .needsPassphrase, .needsNewPassphrase: return engine.isOnline ? .attention : .offline
        case .ready:
            if !engine.isOnline { return .offline }
            if engine.isSyncing { return .syncing }
            return engine.lastError == nil ? .synced : .attention
        }
    }

    var nsColor: NSColor {
        switch self {
        case .none: .clear
        case .synced, .syncing: NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        case .attention: .systemOrange
        case .offline: NSColor(srgbRed: 0.94, green: 0.27, blue: 0.27, alpha: 1)
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

// MARK: - The picture (as in SheepTerm: Google photo, an animal, a figure, or a file)

/// Which picture the account button shows. This Mac only: "google" (the default), "emoji:<face>",
/// "symbol:<SF Symbol>", or "file" (a picture the user chose, kept in Application Support).
final class AccountAvatar: ObservableObject {
    static let shared = AccountAvatar()
    static let didChange = Notification.Name("SheepBrowseAccountAvatarDidChange")

    static let figures = [
        "figure.stand", "figure.wave", "figure.walk", "figure.run", "figure.hiking",
        "figure.mind.and.body", "figure.outdoor.cycle", "figure.pool.swim", "figure.climbing",
        "figure.skiing.downhill", "figure.archery", "figure.dance",
    ]
    /// Animal faces on a background that suits each one; land first, then water; the sheep leads.
    static let landAnimals: [(String, String)] = [
        ("🐑", "#8FB8DE"), ("🐶", "#E8B77D"), ("🐱", "#F4A259"), ("🐭", "#B8B8C8"), ("🐹", "#F2C57C"),
        ("🐰", "#F7C6D9"), ("🦊", "#5B8E7D"), ("🐻", "#C08552"), ("🐼", "#9BC59D"), ("🐨", "#A7C4BC"),
        ("🐯", "#3E7CB1"), ("🦁", "#E07A5F"), ("🐮", "#9CCC65"), ("🐷", "#F5A6B8"), ("🐸", "#6FB07F"),
        ("🐵", "#D9A066"), ("🐔", "#F6D365"), ("🐧", "#7FA7D9"), ("🦉", "#6D5A72"), ("🦄", "#C9A7EB"),
    ]
    static let seaAnimals: [(String, String)] = [
        ("🐳", "#2E86AB"), ("🐬", "#4FB3D9"), ("🐟", "#3FA7D6"), ("🐠", "#1B998B"), ("🐡", "#59C3C3"),
        ("🦈", "#1D4E89"), ("🐙", "#F28482"), ("🦑", "#E76F51"), ("🦀", "#F4A261"), ("🦞", "#2A9D8F"),
        ("🐢", "#52B788"), ("🦭", "#6C9BCF"), ("🪼", "#7B6CF6"), ("🦦", "#A68A64"), ("🐋", "#3A6EA5"),
        ("🦐", "#48CAE4"),
    ]
    static let colors = Dictionary((landAnimals + seaAnimals).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })

    @Published private(set) var choice: String
    @Published private(set) var customPhoto: NSImage?
    private static var customFile: URL { AppFiles.url("avatar.png") }

    private init() {
        choice = UserDefaults.standard.string(forKey: "accountAvatar") ?? "google"
        customPhoto = NSImage(contentsOf: Self.customFile)
    }

    func choose(_ value: String) {
        choice = value
        UserDefaults.standard.set(value, forKey: "accountAvatar")
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Non-modal: a modal panel would close the transient card underneath it.
    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.keep(url) }
        }
    }

    private func keep(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        let side = min(image.size.width, image.size.height)
        let crop = NSRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2, width: side, height: side)
        let square = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            image.draw(in: rect, from: crop, operation: .copy, fraction: 1)
            return true
        }
        guard let tiff = square.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: Self.customFile, options: .atomic)
        customPhoto = NSImage(data: png)
        choose("file")
    }

    /// The current picture, round, `side` points.
    func image(side: CGFloat) -> NSImage {
        let google = GoogleAccount.shared.photo
        let name = GoogleAccount.shared.account?.name ?? ""
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { [choice, customPhoto] rect in
            NSBezierPath(ovalIn: rect).addClip()
            func symbol(_ name: String) {
                NSColor.controlAccentColor.withAlphaComponent(0.55).setFill()
                rect.fill()
                if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: side * 0.5, weight: .medium).applying(.init(paletteColors: [.white]))) {
                    let size = image.size
                    image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
                }
            }
            func text(_ value: String, _ background: NSColor, scale: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white) {
                background.setFill()
                rect.fill()
                let string = NSAttributedString(string: value, attributes: [
                    .font: NSFont.systemFont(ofSize: side * scale, weight: weight), .foregroundColor: color,
                ])
                let size = string.size()
                string.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            }
            if choice.hasPrefix("emoji:") {
                let face = String(choice.dropFirst(6))
                text(face, NSColor(hex: Self.colors[face] ?? "#8FB8DE"), scale: 0.62)
            } else if choice.hasPrefix("symbol:") {
                symbol(String(choice.dropFirst(7)))
            } else if choice == "file", let customPhoto {
                customPhoto.draw(in: rect)
            } else if let google {
                google.draw(in: rect)
            } else {
                text(String(name.prefix(1)).uppercased(), .controlAccentColor, scale: 0.5, weight: .semibold)
            }
            return true
        }
    }
}

extension NSColor {
    /// "#RRGGBB" (the avatar backgrounds).
    convenience init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0x8FB8DE
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - The account card (SheepTerm's account panel)

/// The picture (click it to change it), who is signed in and how Sync is doing, then Sync's controls.
/// Signed out of Sync: what Sync is, and one button.
struct AccountCard: View {
    @ObservedObject private var avatar = AccountAvatar.shared
    @State private var editingPicture: Bool
    private var engine: SyncEngine { SyncController.shared.engine }

    init(startEditing: Bool = false) {
        _editingPicture = State(initialValue: startEditing)
    }

    var body: some View {
        VStack(spacing: 0) {
            if AccountButton.hasAccount { header }
            if engine.phase == .signedOut || engine.phase == .signingIn {
                signInCard
            } else {
                SyncSettingsView(showsHeader: false)
                    .scrollDisabled(true)
            }
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { editingPicture.toggle() }
            } label: {
                ZStack {
                    Image(nsImage: avatar.image(side: 64)).resizable().frame(width: 64, height: 64)
                    let state = SyncRing.state
                    if state != .none {
                        Circle().stroke(state.color, lineWidth: 3).frame(width: 76, height: 76)
                    }
                }
                .frame(width: 76, height: 76)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: editingPicture ? "chevron.up.circle.fill" : "pencil.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                }
            }
            .buttonStyle(.plain)
            .help(editingPicture ? "Done" : "Change picture")
            Text(GoogleAccount.shared.account?.name ?? engine.account ?? "Google account")
                .font(.system(size: 13, weight: .semibold))
            if let email = engine.account ?? GoogleAccount.shared.account?.email {
                Text(email).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !status.isEmpty {
                Text(status).font(.system(size: 11)).foregroundStyle(SyncRing.state == .synced ? .green : .secondary)
            }
            if editingPicture {
                AvatarPicker()
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .padding(.top, 18)
        .padding(.horizontal, 16)
    }

    private var signInCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Sync your favorites").font(.system(size: 14, weight: .semibold))
            Text("Favorites, passwords and settings on every Mac — encrypted with your passphrase before they leave this one, kept in your own Google Drive.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if engine.phase == .signingIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in the tab that opened…").font(.system(size: 12))
                }
                .padding(.top, 4)
                Button("Cancel") { engine.cancelSignIn() }.controlSize(.small)
            } else {
                Button {
                    Task { await engine.signIn() }
                } label: {
                    Text("Sign in with Google").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
            }
            if let error = engine.lastError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var status: String {
        switch engine.phase {
        case .ready:
            if !engine.isOnline { return "Offline — will sync when back online" }
            if engine.isSyncing { return "Syncing…" }
            guard let last = engine.lastSync else { return "Sync on" }
            return "Synced \(last.formatted(.relative(presentation: .named)))"
        case .needsPassphrase: return "Enter your sync passphrase on this Mac"
        case .needsNewPassphrase: return "Choose a passphrase to turn on sync"
        case .checkingVault: return "Checking Google Drive…"
        default: return ""
        }
    }
}

/// The picture choices: Google photo, animals, figures, or a file.
struct AvatarPicker: View {
    @ObservedObject private var avatar = AccountAvatar.shared

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 8), spacing: 8) {
            if let photo = GoogleAccount.shared.photo {
                cell("google", help: "Google account photo") { Image(nsImage: photo).resizable().scaledToFill() }
            }
            ForEach(AccountAvatar.landAnimals + AccountAvatar.seaAnimals, id: \.0) { face, hex in
                cell("emoji:\(face)", help: nil) {
                    ZStack { Circle().fill(Color(nsColor: NSColor(hex: hex))); Text(face).font(.system(size: 17)) }
                }
            }
            ForEach(AccountAvatar.figures, id: \.self) { name in
                cell("symbol:\(name)", help: nil) {
                    ZStack {
                        Circle().fill(Color.accentColor.opacity(0.55))
                        Image(systemName: name).font(.system(size: 14)).foregroundStyle(.white)
                    }
                }
            }
            Button { avatar.chooseFile() } label: {
                Group {
                    if let photo = avatar.customPhoto {
                        Image(nsImage: photo).resizable().scaledToFill()
                    } else {
                        ZStack { Circle().fill(Color.secondary.opacity(0.2)); Image(systemName: "photo.badge.plus").font(.system(size: 12)) }
                    }
                }
                .frame(width: 28, height: 28)
                .clipShape(Circle())
                .overlay(Circle().stroke(avatar.choice == "file" ? Color.accentColor : .clear, lineWidth: 2).padding(-2))
            }
            .buttonStyle(.plain)
            .help("Choose a picture…")
        }
    }

    private func cell(_ value: String, help: String?, @ViewBuilder content: () -> some View) -> some View {
        Button { avatar.choose(value) } label: {
            content()
                .frame(width: 28, height: 28)
                .clipShape(Circle())
                .overlay(Circle().stroke(avatar.choice == value ? Color.accentColor : .clear, lineWidth: 2).padding(-2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
    }
}
