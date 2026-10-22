import AppKit
import LocalAuthentication
import UniformTypeIdentifiers
import Security
import WebKit

// MARK: - The vault

/// Which page a login belongs to: its ORIGIN, compared exactly (scheme, host, port) — never a "site":
/// alice.github.io must not be offered bob.github.io's login, and an https login is never offered on http.
/// Stored as `host` for https on 443 (what entries saved before 1.0 (3) are), otherwise
/// `scheme://host[:port]` (a switch's http admin page: "http://192.168.1.1").
enum LoginKey {
    static func key(scheme: String, host: String, port: Int?) -> String {
        var host = host.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let scheme = scheme.lowercased()
        let defaultPort = scheme == "https" ? 443 : 80
        let explicitPort = (port ?? 0) != 0 && port != defaultPort ? port : nil
        if scheme == "https" && explicitPort == nil { return host }
        return "\(scheme)://\(host)" + (explicitPort.map { ":\($0)" } ?? "")
    }

    static func key(for url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return key(scheme: scheme, host: host, port: url.port)
    }

    /// `location.origin` of the page, for the script to compare before it fills anything.
    static func jsOrigin(scheme: String, host: String, port: Int) -> String {
        let defaultPort = scheme == "https" ? 443 : 80
        return "\(scheme)://\(host)" + (port != 0 && port != defaultPort ? ":\(port)" : "")
    }

    /// The host part of a key (for icons).
    static func host(of key: String) -> String {
        URL(string: key.contains("://") ? key : "https://\(key)")?.host ?? key
    }
}

struct SavedPassword: Codable, Identifiable, Equatable {
    var id = UUID()
    /// A `LoginKey` (the name is the vault format).
    var host: String
    var username: String
    var password: String
    var created = Date()
    var lastUsed: Date?
}

/// Saved logins. ALL of them live in ONE Keychain item ("vault"): a single item means macOS asks at most
/// once if it ever needs to ask about the app's access, and nothing is ever written to disk outside the
/// Keychain. Filling or showing a password needs Touch ID (or the Mac's password).
final class PasswordStore {
    static let shared = PasswordStore()
    static let didChange = Notification.Name("SheepBrowsePasswordsDidChange")
    private let service = "Bestchaan.SheepBrowse"
    private let account = "vault"
    private var cache: [SavedPassword]?
    private var lastAuthentication: Date?
    /// The Keychain item exists but could not be read (locked, access denied): Sync must not read the
    /// empty list as "every password was deleted".
    private(set) var loadFailed = false

    private(set) var all: [SavedPassword] {
        get {
            if let cache { return cache }
            let loaded = readVault()
            cache = loaded
            return loaded
        }
        set {
            cache = newValue
            writeVault(newValue)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// Logins for exactly this origin (a `LoginKey`), most recently used first.
    func entries(forKey key: String) -> [SavedPassword] {
        all.filter { $0.host == key }
            .sorted { ($0.lastUsed ?? $0.created) > ($1.lastUsed ?? $1.created) }
    }

    enum SaveKind { case new, update, same }

    func kind(host: String, username: String, password: String) -> SaveKind {
        guard let existing = all.first(where: { $0.host == host && $0.username == username }) else { return .new }
        return existing.password == password ? .same : .update
    }

    func save(host: String, username: String, password: String) {
        var list = all
        if let index = list.firstIndex(where: { $0.host == host && $0.username == username }) {
            list[index].password = password
            list[index].lastUsed = Date()
        } else {
            list.append(SavedPassword(host: host, username: username, password: password))
        }
        all = list
    }

    func markUsed(_ id: UUID) {
        guard var list = cache, let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].lastUsed = Date()
        all = list
    }

    func delete(_ ids: Set<UUID>) {
        all = all.filter { !ids.contains($0.id) }
    }

    /// Sync: entries from another Mac (by id), and ids deleted there.
    func applySynced(upserts: [SavedPassword], deletes: Set<UUID>) {
        var list = all.filter { !deletes.contains($0.id) }
        for entry in upserts {
            if let index = list.firstIndex(where: { $0.id == entry.id }) { list[index] = entry } else { list.append(entry) }
        }
        all = list
    }

    /// Touch ID (or the login password). A success is good for 30 s, so a two-step sign-in (email, then
    /// password) asks once.
    func authenticate(reason: String) async -> Bool {
        if let last = lastAuthentication, Date().timeIntervalSince(last) < 30 { return true }
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok { lastAuthentication = Date() }
            return ok
        } catch {
            return false
        }
    }

    // MARK: Import (Chrome / Apple Passwords / Safari CSV)

    /// Columns are found by name: url|URL|Website, username|Username, password|Password. Returns the count.
    func importCSV(_ text: String) -> Int {
        let rows = CSV.parse(text)
        guard let header = rows.first?.map({ $0.lowercased().trimmingCharacters(in: .whitespaces) }) else { return 0 }
        func column(_ names: [String]) -> Int? { header.firstIndex { names.contains($0) } }
        guard let urlColumn = column(["url", "website", "login_uri", "web site"]),
              let userColumn = column(["username", "login", "login_username", "user name"]),
              let passColumn = column(["password", "login_password"]) else { return 0 }
        var list = all
        var count = 0
        for row in rows.dropFirst() where row.count > max(urlColumn, userColumn, passColumn) {
            let raw = row[urlColumn]
            guard let url = URL(string: raw).flatMap({ $0.host == nil ? nil : $0 }) ?? URL(string: "https://" + raw),
                  let host = LoginKey.key(for: url), !row[passColumn].isEmpty else { continue }
            if let index = list.firstIndex(where: { $0.host == host && $0.username == row[userColumn] }) {
                list[index].password = row[passColumn]
            } else {
                list.append(SavedPassword(host: host, username: row[userColumn], password: row[passColumn]))
            }
            count += 1
        }
        all = list
        return count
    }

    // MARK: Keychain

    private func readVault() -> [SavedPassword] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        loadFailed = status != errSecSuccess && status != errSecItemNotFound
        guard status == errSecSuccess, let data = result as? Data else { return [] }
        guard let list = try? JSONDecoder().decode([SavedPassword].self, from: data) else {
            loadFailed = true
            return []
        }
        return list
    }

    private func writeVault(_ list: [SavedPassword]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "SheepBrowse Passwords"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(add as CFDictionary, nil)
        } else if status != errSecSuccess {
            NSLog("SheepBrowse: could not save passwords (\(status))")
        }
    }
}

enum CSV {
    /// RFC 4180: quoted fields, doubled quotes, CR/LF line ends.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = Array(text).makeIterator()
        var pending: Character?
        while let c = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else { field.append(c) }
                continue
            }
            switch c {
            case "\"": quoted = true
            case ",": row.append(field); field = ""
            case "\n", "\r\n", "\r":
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            default: field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

// MARK: - The page side (runs in the app's own content world; a page cannot call it)

enum PasswordAutofill {
    static let world = WKContentWorld.world(name: "SheepBrowsePasswords")
    static let handler = MessageHandler()

    static func install(on controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        controller.add(handler, contentWorld: world, name: "sheepPasswords")
    }

    final class MessageHandler: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let webView = message.webView as? SheepWebView, let tab = webView.tab,
                  let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            let origin = message.frameInfo.securityOrigin
            let host = LoginKey.key(scheme: origin.protocol, host: origin.host, port: origin.port)
            let jsOrigin = LoginKey.jsOrigin(scheme: origin.protocol, host: origin.host, port: origin.port)
            guard let controller = tab.delegate as? BrowserWindowController, !origin.host.isEmpty else { return }
            switch type {
            case "focus":
                let rect = (body["rect"] as? [Double]) ?? []
                guard rect.count == 4 else { return }
                controller.passwordField(focusedIn: tab, host: host, origin: jsOrigin, cssRect: CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]),
                                         newPassword: body["newPassword"] as? Bool ?? false)
            case "blur":
                controller.passwordFieldBlurred(in: tab)
            case "submit":
                let user = body["username"] as? String ?? ""
                guard let pass = body["password"] as? String, !pass.isEmpty, !tab.isPrivate else { return }
                controller.offerToSavePassword(tab: tab, host: host, username: user, password: pass)
            default: break
            }
        }
    }

    /// Fills the login form around the focused field (or the first one) — only when the document is still
    /// on the `expected` origin (a navigation between the click and the fill must not hand the login to another site).
    static func fill(_ entry: SavedPassword, in webView: WKWebView, expectedOrigin: String) {
        webView.callAsyncJavaScript("return window.__sheepFill(user, pass, expected);",
                                    arguments: ["user": entry.username, "pass": entry.password, "expected": expectedOrigin],
                                    in: nil, in: world, completionHandler: nil)
    }

    static let script = #"""
    (() => {
      const post = m => { try { window.webkit.messageHandlers.sheepPasswords.postMessage(m); } catch (e) {} };
      const visible = el => { const r = el.getBoundingClientRect(); const s = getComputedStyle(el);
        return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
      const isPassword = el => el instanceof HTMLInputElement && el.type === 'password';
      const userish = el => {
        if (!(el instanceof HTMLInputElement)) return false;
        const t = (el.type || 'text').toLowerCase();
        if (!['text', 'email', 'tel', ''].includes(t)) return false;
        const ac = (el.autocomplete || '').toLowerCase();
        if (ac.includes('username') || ac === 'email' || t === 'email') return true;
        const hint = [el.name, el.id, el.placeholder, el.getAttribute('aria-label')].join(' ');
        return /user|login|e-?mail|account|identifier|signin/i.test(hint);
      };
      const scope = el => (el && el.form) || document;
      const passwordsIn = root => [...root.querySelectorAll('input[type=password]')].filter(visible);
      const userFor = (root, pass) => {
        const inputs = [...root.querySelectorAll('input')].filter(i => visible(i) && !isPassword(i));
        const before = pass ? inputs.filter(i => i.compareDocumentPosition(pass) & Node.DOCUMENT_POSITION_FOLLOWING) : inputs;
        return before.filter(userish).pop() || before.filter(i => ['text', 'email'].includes(i.type)).pop() || null;
      };
      let lastUser = '';
      let focused = null;

      const report = el => {
        const r = el.getBoundingClientRect();
        const newPassword = isPassword(el) &&
          ((el.autocomplete || '').includes('new-password') || passwordsIn(scope(el)).length >= 2);
        post({ type: 'focus', rect: [r.left, r.top, r.width, r.height], newPassword });
      };
      document.addEventListener('focusin', e => {
        const el = e.target;
        if (!(el instanceof HTMLInputElement)) return;
        const loginPage = passwordsIn(document).length > 0;
        if (isPassword(el) || (userish(el) && (loginPage || /username|email/.test(el.autocomplete || '') || el.type === 'email'))) {
          focused = el;
          report(el);
        }
      }, true);
      document.addEventListener('focusout', () => { focused = null; post({ type: 'blur' }); }, true);
      window.addEventListener('scroll', () => { if (focused) post({ type: 'blur' }); }, true);
      document.addEventListener('input', e => { if (userish(e.target) && e.target.value) lastUser = e.target.value; }, true);

      let lastSent = '';
      const capture = root => {
        const pass = passwordsIn(root || document).find(p => p.value) || passwordsIn(document).find(p => p.value);
        if (!pass) return;
        const userField = userFor(scope(pass), pass);
        const user = (userField && userField.value) || lastUser;
        const key = user + '\u0000' + pass.value;
        if (key === lastSent) return;
        lastSent = key;
        post({ type: 'submit', username: user, password: pass.value });
      };
      document.addEventListener('submit', e => capture(e.target), true);
      document.addEventListener('click', e => {
        const b = e.target.closest && e.target.closest('button, input[type=submit], [role=button]');
        if (b) capture(b.form || document);
      }, true);
      document.addEventListener('keydown', e => {
        if (e.key === 'Enter' && e.target instanceof HTMLInputElement) capture(scope(e.target));
      }, true);

      const setValue = (el, value) => {
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        el.focus();
        setter.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      };
      window.__sheepFill = (user, pass, expected) => {
        if (location.origin.toLowerCase() !== String(expected).toLowerCase()) return 'other-origin';
        const anchor = focused || document.activeElement;
        const root = scope(anchor instanceof HTMLInputElement ? anchor : null);
        const passField = passwordsIn(root)[0] || passwordsIn(document)[0];
        const userField = userFor(passField ? scope(passField) : root, passField) ||
                          (anchor instanceof HTMLInputElement && userish(anchor) ? anchor : null);
        if (userField && user) setValue(userField, user);
        if (passField) setValue(passField, pass);
        lastUser = user;
        return passField ? 'filled' : (userField ? 'user-only' : 'none');
      };
      // A new account: the generated password goes in every password box of the form (password + confirm).
      window.__sheepFillNew = (pass, expected) => {
        if (location.origin.toLowerCase() !== String(expected).toLowerCase()) return 0;
        const anchor = focused || document.activeElement;
        const boxes = passwordsIn(scope(anchor instanceof HTMLInputElement ? anchor : null));
        boxes.forEach(b => setValue(b, pass));
        return boxes.length;
      };
    })();
    """#
}

// MARK: - "Save this password?" card

final class SavePasswordCard: GlassCapsule {
    var onAnswer: ((Answer) -> Void)?
    enum Answer { case save, notNow, never }

    init(host: String, username: String, update: Bool) {
        super.init(radius: 18, interactive: false)
        let badge = NSImageView(image: NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))!)
        badge.contentTintColor = .white
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 9
        badge.layer?.cornerCurve = .continuous
        badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: update ? "Update saved password?" : "Save this password?")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "\(username.isEmpty ? "(no user name)" : username) · \(host)\nKept in your Keychain, filled with Touch ID.")
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor

        let never = button(update ? "No" : "Never", #selector(neverTapped))
        let later = button("Not Now", #selector(laterTapped))
        let save = button(update ? "Update" : "Save", #selector(saveTapped))
        save.keyEquivalent = "\r"
        save.bezelColor = .controlAccentColor
        never.isHidden = update

        let texts = NSStackView(views: [title, detail]).vertical()
        let top = NSStackView(views: [badge, texts])
        top.alignment = .top
        top.spacing = 10
        let buttons = NSStackView(views: update ? [later, save] : [never, later, save])
        buttons.spacing = 6
        let stack = NSStackView(views: [top, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 32), badge.heightAnchor.constraint(equalToConstant: 32),
            detail.widthAnchor.constraint(equalToConstant: 230),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .glass
        button.controlSize = .regular
        return button
    }

    @objc private func saveTapped() { onAnswer?(.save) }
    @objc private func laterTapped() { onAnswer?(.notNow) }
    @objc private func neverTapped() { onAnswer?(.never) }

    var preferredSize: NSSize { content.subviews.first.map { NSSize(width: $0.fittingSize.width + 28, height: $0.fittingSize.height + 26) } ?? .zero }
}

