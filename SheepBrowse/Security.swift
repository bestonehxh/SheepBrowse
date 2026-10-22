import AppKit
import CryptoKit
import SecurityInterface
import WebKit

// MARK: - What the lock in the address field says

enum SiteSecurity {
    case secure, trustedByUser, mixed, insecure

    static func state(for tab: BrowserTab?) -> SiteSecurity {
        guard let tab, let url = tab.url, url.scheme == "https" else { return .insecure }
        if tab.trustedCertificate { return .trustedByUser }
        return tab.isSecure || tab.isLoading ? .secure : .mixed
    }
}

// MARK: - Certificates the user chose to trust

/// A server whose certificate macOS does not trust (a switch's or firewall's self-signed one) can be let
/// in once (this app run) or trusted: then the leaf certificate's SHA-256 is remembered for that
/// host:port, and a DIFFERENT certificate later is never accepted silently.
enum CertificateTrust {
    private static let key = "trustedCertificates"
    private static var onceAllowed: Set<String> = []

    static func serverKey(host: String, port: Int) -> String { "\(host.lowercased()):\(port)" }

    static func pinned(_ server: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[server]
    }

    static func pin(_ fingerprint: String, for server: String) {
        var table = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        table[server] = fingerprint
        UserDefaults.standard.set(table, forKey: key)
    }

    static func unpin(_ server: String) {
        var table = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        table[server] = nil
        UserDefaults.standard.set(table, forKey: key)
        onceAllowed = onceAllowed.filter { !$0.hasPrefix(server + "#") }
    }

    static func allowOnce(_ fingerprint: String, for server: String) { onceAllowed.insert(server + "#" + fingerprint) }
    static func isAllowedOnce(_ fingerprint: String, for server: String) -> Bool { onceAllowed.contains(server + "#" + fingerprint) }

    static var all: [String: String] { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }

    static func fingerprint(of trust: SecTrust) -> String? {
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return nil }
        let data = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The system's verdict, evaluated off the main thread (it may check revocation over the network).
    static func systemTrusts(_ trust: SecTrust) async -> Bool {
        nonisolated(unsafe) let trust = trust
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue.global(qos: .userInitiated)
            queue.async {
                SecTrustEvaluateAsyncWithError(trust, queue) { _, trusted, _ in
                    continuation.resume(returning: trusted)
                }
            }
        }
    }

    /// "AB:CD:…" in two lines of 16 pairs, for reading against a device's own display.
    static func formatted(_ fingerprint: String) -> String {
        let pairs = stride(from: 0, to: fingerprint.count, by: 2).map { offset -> String in
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: offset)
            return String(fingerprint[start..<fingerprint.index(start, offsetBy: 2)]).uppercased()
        }
        return stride(from: 0, to: pairs.count, by: 16).map { pairs[$0..<min($0 + 16, pairs.count)].joined(separator: ":") }
            .joined(separator: "\n")
    }
}

/// A certificate problem on the page a tab is opening, shown as a card over the page.
struct CertificateIssue {
    var url: URL
    var server: String
    var fingerprint: String
    var trust: SecTrust
    /// A certificate was trusted for this server before and this one is different.
    var changed: Bool
}

// MARK: - Challenges

extension BrowserTab {
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            return await serverTrust(challenge)
        case NSURLAuthenticationMethodClientCertificate:
            return await clientCertificate(challenge)
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM:
            return await httpLogin(challenge)
        default:
            return (.performDefaultHandling, nil)
        }
    }

    private func serverTrust(_ challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard let trust = space.serverTrust else { return (.performDefaultHandling, nil) }
        if await CertificateTrust.systemTrusts(trust) { return (.performDefaultHandling, nil) }
        guard let fingerprint = CertificateTrust.fingerprint(of: trust) else { return (.cancelAuthenticationChallenge, nil) }
        let server = CertificateTrust.serverKey(host: space.host, port: space.port)
        let pinned = CertificateTrust.pinned(server)
        if pinned == fingerprint || (pinned == nil && CertificateTrust.isAllowedOnce(fingerprint, for: server)) {
            if isMainServer(space) { trustedCertificate = true }
            return (.useCredential, URLCredential(trust: trust))
        }
        // Only the page's own server gets the card; anything else on another server is refused quietly.
        if isMainServer(space), let target = pendingMainURL ?? url {
            certificateIssue = CertificateIssue(url: target, server: server, fingerprint: fingerprint, trust: trust,
                                                changed: pinned != nil)
            delegate?.tabDidChange(self)
        }
        return (.cancelAuthenticationChallenge, nil)
    }

    private func isMainServer(_ space: URLProtectionSpace) -> Bool {
        guard let target = pendingMainURL ?? url, let host = target.host else { return false }
        let port = target.port ?? (target.scheme == "https" ? 443 : 80)
        return host.lowercased() == space.host.lowercased() && port == space.port
    }

    /// The user's answer on the certificate card.
    func resolveCertificate(trust: Bool, once: Bool) {
        guard let issue = certificateIssue else { return }
        certificateIssue = nil
        if isPrivate && (trust || once) {
            // A private window leaves nothing behind: its "Trust" lasts for this run only.
            CertificateTrust.allowOnce(issue.fingerprint, for: issue.server)
        } else if trust && !issue.changed {
            CertificateTrust.pin(issue.fingerprint, for: issue.server)
        } else if once && !issue.changed {
            CertificateTrust.allowOnce(issue.fingerprint, for: issue.server)
        } else if trust && issue.changed {
            // Replacing a pinned certificate is an explicit, separate choice.
            CertificateTrust.pin(issue.fingerprint, for: issue.server)
        }
        if trust || once { load(issue.url) } else { delegate?.tabDidChange(self) }
    }

    private func clientCertificate(_ challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // The picker is app-modal: only for the page's own server in the tab on screen.
        guard isMainServer(challenge.protectionSpace), delegate?.tabIsSelected(self) == true else { return (.performDefaultHandling, nil) }
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecReturnRef as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity], !identities.isEmpty else { return (.performDefaultHandling, nil) }
        let panel = SFChooseIdentityPanel.shared()!
        panel.setAlternateButtonTitle("Cancel")
        let host = challenge.protectionSpace.host
        guard panel.runModal(forIdentities: identities, message: "\(host) asks for a certificate to identify you.")
                == NSApplication.ModalResponse.OK.rawValue,
              let identity = panel.identity()?.takeUnretainedValue() else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
    }

    private func httpLogin(_ challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // Only the page itself, in the tab on screen: a 401 from an image or iframe of another server must
        // not put a native login sheet over a page the user trusts.
        let space = challenge.protectionSpace
        guard challenge.previousFailureCount < 3, isMainServer(space), delegate?.tabIsSelected(self) == true,
              let window = delegate?.window else { return (.cancelAuthenticationChallenge, nil) }
        let scheme = space.protocol ?? (space.receivesCredentialSecurely ? "https" : "http")
        let saved = PasswordStore.shared.entries(forKey: LoginKey.key(scheme: scheme, host: space.host, port: space.port)).first
        let alert = NSAlert()
        alert.messageText = "Log in to \(space.host)"
        alert.informativeText = space.receivesCredentialSecurely
            ? (space.realm.map { "“\($0)”" } ?? "")
            : "Your password will be sent unencrypted." + (space.realm.map { " (\($0))" } ?? "")
        alert.addButton(withTitle: "Log In")
        alert.addButton(withTitle: "Cancel")
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        user.placeholderString = "User Name"
        user.stringValue = challenge.proposedCredential?.user ?? saved?.username ?? ""
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        pass.placeholderString = "Password"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        box.addSubview(user)
        box.addSubview(pass)
        alert.accessoryView = box
        alert.window.initialFirstResponder = user.stringValue.isEmpty ? user : pass
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(user: user.stringValue, password: pass.stringValue, persistence: .forSession))
    }
}

// MARK: - The card shown over a page whose certificate is not trusted

final class CertificateCardView: NSView {
    private let card = GlassCapsule(radius: 22, interactive: false)
    var onAnswer: ((_ trust: Bool, _ once: Bool) -> Void)?
    private var issue: CertificateIssue?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ issue: CertificateIssue) {
        self.issue = issue
        card.content.subviews.forEach { $0.removeFromSuperview() }

        let symbol = NSImageView(image: NSImage(systemSymbolName: issue.changed ? "exclamationmark.shield.fill" : "lock.trianglebadge.exclamationmark.fill",
                                                accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 38, weight: .regular))!)
        symbol.contentTintColor = issue.changed ? .systemRed : .systemOrange

        let title = NSTextField(labelWithString: issue.changed ? "The certificate has CHANGED" : "This connection is not private")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = issue.changed ? .systemRed : .labelColor

        let host = issue.url.host ?? issue.server
        let body = NSTextField(wrappingLabelWithString: issue.changed
            ? "\(host) presented a different certificate from the one you trusted. Someone may be intercepting the connection — or the device got a new certificate. Check the fingerprint on the device itself before trusting it."
            : "macOS does not trust the certificate of \(host). Devices on your own network (switches, firewalls, printers) often use a self-signed certificate. Compare the fingerprint with the device before you continue.")
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.alignment = .center

        let fingerprintLabel = NSTextField(labelWithString: "SHA-256 fingerprint")
        fingerprintLabel.font = .systemFont(ofSize: 11, weight: .medium)
        fingerprintLabel.textColor = .tertiaryLabelColor
        let fingerprint = NSTextField(wrappingLabelWithString: CertificateTrust.formatted(issue.fingerprint))
        fingerprint.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        fingerprint.textColor = .secondaryLabelColor
        fingerprint.alignment = .center
        fingerprint.isSelectable = true

        let back = NSButton(title: "Go Back", target: self, action: #selector(goBack))
        back.bezelStyle = .glass
        back.keyEquivalent = "\r"
        let details = NSButton(title: "Show Certificate", target: self, action: #selector(showCertificate))
        details.bezelStyle = .glass
        let once = NSButton(title: "Connect Once", target: self, action: #selector(connectOnce))
        once.bezelStyle = .glass
        once.isHidden = issue.changed
        let trust = NSButton(title: issue.changed ? "Trust New Certificate" : "Trust & Connect", target: self, action: #selector(trustAndConnect))
        trust.bezelStyle = .glass
        trust.hasDestructiveAction = issue.changed
        // The go-ahead is green (a CHANGED certificate stays red: destructive).
        if !issue.changed {
            trust.bezelColor = .systemGreen
            trust.contentTintColor = .white
        }

        let buttons = NSStackView(views: [details, once, trust, back])
        buttons.spacing = 8
        let stack = NSStackView(views: [symbol, title, body, fingerprintLabel, fingerprint, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(18, after: body)
        stack.setCustomSpacing(4, after: fingerprintLabel)
        stack.setCustomSpacing(22, after: fingerprint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.content.addSubview(stack)
        NSLayoutConstraint.activate([
            body.widthAnchor.constraint(equalToConstant: 440),
            stack.topAnchor.constraint(equalTo: card.content.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: card.content.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: card.content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: card.content.trailingAnchor, constant: -28),
        ])
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = card.content.subviews.first?.fittingSize ?? NSSize(width: 500, height: 320)
        let width = size.width + 56, height = size.height + 52
        card.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2 - 20, width: width, height: height)
    }

    @objc private func goBack() { onAnswer?(false, false) }
    @objc private func connectOnce() { onAnswer?(false, true) }
    @objc private func trustAndConnect() { onAnswer?(true, false) }

    @objc private func showCertificate() {
        guard let issue, let window else { return }
        SFCertificateTrustPanel().beginSheet(for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil,
                                                      trust: issue.trust, message: issue.url.host ?? issue.server)
    }
}

// MARK: - Site information (the lock button)

final class SiteInfoViewController: NSViewController {
    private let tab: BrowserTab
    private weak var controller: BrowserWindowController?

    init(tab: BrowserTab, controller: BrowserWindowController) {
        self.tab = tab
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let host = tab.url?.host ?? ""
        let state = SiteSecurity.state(for: tab)
        let (symbol, color, heading, text): (String, NSColor, String, String) = {
            switch state {
            case .secure: return ("lock.fill", .systemGreen, "Connection is secure", "Your information (passwords, card numbers) is private when it is sent to this site.")
            case .trustedByUser: return ("lock.badge.checkmark.fill", .systemOrange, "Certificate trusted by you", "macOS does not trust this site's certificate; you chose to trust it.")
            case .mixed: return ("lock.trianglebadge.exclamationmark.fill", .systemOrange, "Parts of this page are not secure", "Some content (images or scripts) was loaded without encryption.")
            case .insecure: return ("exclamationmark.triangle.fill", .systemOrange, "Connection is not secure", "Don't enter passwords or card numbers on this site.")
            }
        }()
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))!)
        icon.contentTintColor = color
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let hostLabel = NSTextField(labelWithString: host)
        hostLabel.font = .systemFont(ofSize: 11.5)
        hostLabel.textColor = .secondaryLabelColor
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        let header = NSStackView(views: [icon, NSStackView(views: [title, hostLabel]).vertical()])
        header.alignment = .top
        header.spacing = 10

        var views: [NSView] = [header, body]
        if tab.webView?.serverTrust != nil {
            views.append(link("Show Certificate", #selector(showCertificate)))
        }
        if let url = tab.url, let urlHost = url.host,
           CertificateTrust.pinned(CertificateTrust.serverKey(host: urlHost, port: url.port ?? 443)) != nil {
            views.append(link("Stop Trusting This Certificate", #selector(forget)))
        }
        // What this site may use (asked before, or used now): Ask / Allow / Block.
        if let origin = SitePermissionStore.origin(of: tab.url) {
            let used = SitePermission.allCases.filter {
                SitePermissionStore.decision($0, for: origin) != nil
                    || ($0 == .camera && tab.cameraState != .none) || ($0 == .microphone && tab.microphoneState != .none)
            }
            for permission in used {
                let label = NSTextField(labelWithString: permission.title)
                label.font = .systemFont(ofSize: 12)
                let icon = NSImageView(image: NSImage(systemSymbolName: permission.symbol, accessibilityDescription: nil)!)
                icon.contentTintColor = .secondaryLabelColor
                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.addItems(withTitles: ["Ask", "Allow", "Block"])
                switch SitePermissionStore.decision(permission, for: origin) {
                case .allow: popup.selectItem(at: 1)
                case .deny: popup.selectItem(at: 2)
                case nil: popup.selectItem(at: 0)
                }
                popup.controlSize = .small
                popup.target = self
                popup.action = #selector(changePermission(_:))
                popup.identifier = NSUserInterfaceItemIdentifier(permission.rawValue)
                let row = NSStackView(views: [icon, label, NSView(), popup])
                row.spacing = 6
                row.widthAnchor.constraint(equalToConstant: 280).isActive = true
                views.append(row)
            }
        }
        if let site = AddressInput.site(of: host) {
            let blocker = NSButton(checkboxWithTitle: "Block ads and trackers on this site", target: self, action: #selector(toggleAds(_:)))
            blocker.state = Settings.blockAds && !Settings.adBlockAllowedSites.contains(site) ? .on : .off
            blocker.isEnabled = Settings.blockAds
            views.append(blocker)
        }
        let stack = NSStackView(views: views).vertical()
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        body.widthAnchor.constraint(equalToConstant: 280).isActive = true
        view = stack
    }

    private func link(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .linkColor
        button.font = .systemFont(ofSize: 12)
        return button
    }

    @objc private func showCertificate() {
        guard let trust = tab.webView?.serverTrust, let window = view.window else { return }
        nonisolated(unsafe) let unsafeTrust = trust
        let panel = SFCertificateTrustPanel()
        panel.beginSheet(for: controller?.window ?? window, modalDelegate: nil, didEnd: nil, contextInfo: nil,
                         trust: unsafeTrust, message: tab.url?.host ?? "")
        view.window?.performClose(nil)
    }

    @objc private func changePermission(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue, let permission = SitePermission(rawValue: raw),
              let origin = SitePermissionStore.origin(of: tab.url) else { return }
        let decision: PermissionDecision? = [nil, .allow, .deny][sender.indexOfSelectedItem]
        // Open tabs follow (capture that is no longer allowed stops) — SitePermissionStore.set does it.
        SitePermissionStore.set(decision, permission, for: origin)
    }

    @objc private func forget() {
        guard let url = tab.url, let host = url.host else { return }
        CertificateTrust.unpin(CertificateTrust.serverKey(host: host, port: url.port ?? 443))
        view.window?.performClose(nil)
    }

    @objc private func toggleAds(_ sender: NSButton) {
        guard let site = AddressInput.site(of: tab.url?.host) else { return }
        var allowed = Settings.adBlockAllowedSites
        if sender.state == .on { allowed.remove(site) } else { allowed.insert(site) }
        Settings.adBlockAllowedSites = allowed
        WebEngine.shared.refreshBlockList()
        tab.webView?.reload()
        controller?.refreshChrome()
    }
}

extension NSStackView {
    func vertical() -> NSStackView {
        orientation = .vertical
        alignment = .leading
        spacing = 2
        return self
    }
}
