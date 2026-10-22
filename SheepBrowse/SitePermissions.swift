import AppKit
import UserNotifications
import WebKit

// MARK: - What each site may use

/// Per-site permissions (camera, microphone, location, notifications), remembered per ORIGIN
/// ("https://meet.google.com"). Private windows remember nothing. Shown in Settings → Websites and in the
/// site information popover, where they can be changed or removed.
enum SitePermission: String, CaseIterable, Codable {
    case camera, microphone, location, notifications

    var title: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .location: "Location"
        case .notifications: "Notifications"
        }
    }

    var symbol: String {
        switch self {
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        case .location: "location.fill"
        case .notifications: "bell.fill"
        }
    }

    /// "use your camera", "send you notifications"…
    var request: String {
        switch self {
        case .camera: "use your camera"
        case .microphone: "use your microphone"
        case .location: "know your location"
        case .notifications: "send you notifications"
        }
    }
}

enum PermissionDecision: String, Codable { case allow, deny }

enum SitePermissionStore {
    static let didChange = Notification.Name("SheepBrowseSitePermissionsDidChange")
    private static let key = "sitePermissions"

    /// nil for anything that is not a real web origin (a sandboxed page's opaque origin "://", file://):
    /// those never get a permission, so they can't share one key.
    static func origin(_ origin: WKSecurityOrigin) -> String? {
        guard ["http", "https"].contains(origin.protocol), !origin.host.isEmpty else { return nil }
        return LoginKey.jsOrigin(scheme: origin.protocol, host: origin.host, port: origin.port)
    }

    /// How the bubble names the site: the host for https on 443, the whole origin otherwise (so
    /// http://bank.com and https://bank.com:8443 never look like the real site).
    static func display(_ origin: String) -> String {
        guard let url = URL(string: origin), let host = url.host else { return origin }
        return url.scheme == "https" && url.port == nil ? host : origin
    }

    /// Notifications need a secure page (https, or localhost while developing).
    static func isSecure(_ origin: String) -> Bool {
        guard let url = URL(string: origin) else { return false }
        return url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1"
    }

    static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme, let host = url.host, ["http", "https"].contains(scheme) else { return nil }
        return LoginKey.jsOrigin(scheme: scheme, host: host, port: url.port ?? 0)
    }

    /// [origin: [permission: decision]]
    static var all: [String: [String: String]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
    }

    static func decision(_ permission: SitePermission, for origin: String) -> PermissionDecision? {
        all[origin]?[permission.rawValue].flatMap(PermissionDecision.init(rawValue:))
    }

    static func set(_ decision: PermissionDecision?, _ permission: SitePermission, for origin: String) {
        var table = all
        var site = table[origin] ?? [:]
        site[permission.rawValue] = decision?.rawValue
        table[origin] = site.isEmpty ? nil : site
        UserDefaults.standard.set(table, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["origin": origin])
        // Open tabs follow at once: their own "this time" answers for it go, and capture that is no
        // longer allowed stops.
        for tab in BrowserWindowController.all.flatMap(\.tabs) { tab.sitePermissionsChanged(for: origin, permission: permission) }
    }
}

// MARK: - Asking (a bubble under the site icon, as in Chrome)

final class PermissionPromptController: NSViewController {
    /// `dismissed`: the bubble went away unanswered (tab switched or closed) — not allowed, nothing saved.
    /// `decided`: Settings answered it while it waited in the queue.
    enum Answer { case always, once, never, dismissed, decided(Bool) }
    private let origin: String
    private let permissions: [SitePermission]
    var onAnswer: ((Answer) -> Void)?

    init(origin: String, permissions: [SitePermission]) {
        self.origin = origin
        self.permissions = permissions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(wrappingLabelWithString: "\(SitePermissionStore.display(origin)) wants to")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        var rows: [NSView] = [title]
        for permission in permissions {
            let icon = NSImageView(image: NSImage(systemSymbolName: permission.symbol, accessibilityDescription: nil)!)
            icon.contentTintColor = .controlAccentColor
            let text = NSTextField(labelWithString: permission.request.prefix(1).uppercased() + permission.request.dropFirst())
            text.font = .systemFont(ofSize: 12.5)
            let row = NSStackView(views: [icon, text])
            row.spacing = 8
            rows.append(row)
        }
        // No Return default, and nothing answers for a moment after the bubble appears: a page must not
        // be able to time a request under a click or an Enter it asked for ("double-click to start").
        let always = button("Allow on Every Visit", .always)
        always.bezelColor = .controlAccentColor
        let once = button("Allow This Time", .once)
        let never = button("Don't Allow", .never)
        armed = [always, once, never]
        armed.forEach { $0.isEnabled = false }
        let buttons = NSStackView(views: [always, once, never])
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 6
        for b in [always, once, never] { b.widthAnchor.constraint(equalToConstant: 240).isActive = true }
        rows.append(buttons)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: rows[rows.count - 2])
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        title.widthAnchor.constraint(equalToConstant: 240).isActive = true
        view = stack
    }

    private var armed: [NSButton] = []
    private var armedAt = 0

    override func viewDidAppear() {
        super.viewDidAppear()
        rearm()
    }

    /// Buttons off for a moment (when shown, and again whenever the window comes back to the front).
    func rearm() {
        armed.forEach { $0.isEnabled = false }
        armedAt += 1
        let ticket = armedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.armedAt == ticket else { return }
            self.armed.forEach { $0.isEnabled = true }
        }
    }

    private func button(_ title: String, _ answer: Answer) -> NSButton {
        let button = ClosureButton(title: title) { [weak self] in self?.onAnswer?(answer) }
        button.bezelStyle = .glass
        button.controlSize = .large
        return button
    }
}

// MARK: - Web notifications (bridged to macOS notifications)

/// WebKit has no public Notifications API for apps: a page-world script provides `Notification` (and
/// `ServiceWorkerRegistration.showNotification`) and posts to the app, which checks the sender's origin
/// against the site's permission before anything reaches Notification Center. Works while the page is
/// open (no push when it is closed).
final class WebNotificationBridge: NSObject, WKScriptMessageHandler, UNUserNotificationCenterDelegate {
    static let shared = WebNotificationBridge()

    static func install(on controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.add(shared, contentWorld: .page, name: "sheepNotify")
    }

    func start() {
        UNUserNotificationCenter.current().delegate = self
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let webView = message.webView as? SheepWebView, let tab = webView.tab,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        // No real web origin (sandboxed, file://), not secure, or a private window: no notifications.
        guard let origin = SitePermissionStore.origin(message.frameInfo.securityOrigin),
              SitePermissionStore.isSecure(origin), !tab.isPrivate else {
            if type == "request" {
                webView.callAsyncJavaScript("window.__sheepNotifyAnswer && window.__sheepNotifyAnswer('denied')", arguments: [:],
                                            in: nil, in: .page, completionHandler: nil)
            }
            return
        }
        switch type {
        case "request":
            tab.requestPermissions([.notifications], origin: origin) { granted in
                let state = granted ? "granted" : "denied"
                webView.callAsyncJavaScript("window.__sheepNotifyAnswer && window.__sheepNotifyAnswer(state)",
                                            arguments: ["state": state], in: nil, in: .page, completionHandler: nil)
                if granted { Self.askMacOnce() }
            }
        case "show":
            let decision = SitePermissionStore.decision(.notifications, for: origin)
            guard decision != .deny, decision == .allow || tab.onceAllowed(.notifications, origin: origin),
                  let title = body["title"] as? String else { return }
            let content = UNMutableNotificationContent()
            content.title = String(title.prefix(200))
            content.body = String((body["body"] as? String ?? "").prefix(1000))
            content.subtitle = URL(string: origin)?.host ?? ""
            content.userInfo = ["tab": tab.id.uuidString, "id": body["id"] as? String ?? ""]
            content.threadIdentifier = origin
            let tag = (body["tag"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(origin)#\(tag)", content: content, trigger: nil))
        default: break
        }
    }

    /// The Mac's own permission for the app, asked the first time a site is allowed.
    private static func askMacOnce() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// A click brings the tab to the front and tells the page (its `onclick`).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let tabID = info["tab"] as? String
        let id = info["id"] as? String ?? ""
        await MainActor.run {
            guard let tab = BrowserWindowController.all.flatMap(\.tabs).first(where: { $0.id.uuidString == tabID }) else { return }
            BrowserWindowController.reveal(tab)
            NSApp.activate()
            tab.webView?.callAsyncJavaScript("window.__sheepNotifyClick && window.__sheepNotifyClick(id)", arguments: ["id": id],
                                             in: nil, in: .page, completionHandler: nil)
        }
    }

    static let script = #"""
    (() => {
      if (window.__sheepNotifyInstalled) return;
      window.__sheepNotifyInstalled = true;
      const post = m => { try { window.webkit.messageHandlers.sheepNotify.postMessage(m); } catch (e) {} };
      let permission = 'default';
      const waiting = [];
      const live = new Map();
      window.__sheepNotifyAnswer = state => { permission = state; while (waiting.length) waiting.shift()(state); };
      window.__sheepNotifySet = state => { permission = state; };
      window.__sheepNotifyClick = id => {
        const n = live.get(id);
        if (!n) return;
        const event = new Event('click');
        if (typeof n.onclick === 'function') n.onclick(event);
        n.dispatchEvent(event);
      };
      class SheepNotification extends EventTarget {
        constructor(title, options = {}) {
          super();
          this.title = String(title); this.body = options.body || ''; this.tag = options.tag || '';
          this.icon = options.icon || ''; this.data = options.data; this.onclick = null;
          const id = Math.random().toString(36).slice(2);
          live.set(id, this);
          if (permission === 'granted') post({ type: 'show', id, title: this.title, body: String(this.body), tag: String(this.tag) });
        }
        close() {}
        static get permission() { return permission; }
        static requestPermission(callback) {
          return new Promise(resolve => {
            const done = state => { if (callback) callback(state); resolve(state); };
            if (permission !== 'default') return done(permission);
            waiting.push(done);
            post({ type: 'request' });
          });
        }
      }
      Object.defineProperty(window, 'Notification', { value: SheepNotification, writable: true, configurable: true });
      if (window.ServiceWorkerRegistration) {
        ServiceWorkerRegistration.prototype.showNotification = function (title, options) {
          new SheepNotification(title, options);
          return Promise.resolve();
        };
      }
      if (navigator.permissions && navigator.permissions.query) {
        const query = navigator.permissions.query.bind(navigator.permissions);
        navigator.permissions.query = d => d && d.name === 'notifications'
          ? Promise.resolve({ state: permission === 'granted' ? 'granted' : permission === 'denied' ? 'denied' : 'prompt', onchange: null })
          : query(d);
      }
    })();
    """#
}

// MARK: - The tab's side

extension BrowserTab {
    /// What the site already has for all of `wanted`: true/false, or nil = ask.
    func currentDecision(_ wanted: [SitePermission], origin: String) -> Bool? {
        let decided = wanted.map { SitePermissionStore.decision($0, for: origin) }
        if decided.contains(.deny) || wanted.contains(where: { deniedHere($0, origin: origin) }) { return false }
        if wanted.allSatisfy({ SitePermissionStore.decision($0, for: origin) == .allow || onceAllowed($0, origin: origin) }) { return true }
        return nil
    }

    /// Asks (or answers from what the site already has). `completion(true)` = allowed.
    func requestPermissions(_ wanted: [SitePermission], origin: String, completion: @escaping (Bool) -> Void) {
        if let known = currentDecision(wanted, origin: origin) { return completion(known) }
        guard let controller = delegate as? BrowserWindowController, controller.tabIsSelected(self) else { return completion(false) }
        controller.askPermission(for: self, origin: origin, permissions: wanted) { [weak self] answer in
            guard let self else { return completion(false) }
            switch answer {
            case .always:
                // A saved "allow" only — no hidden per-tab grant that would outlive a later Block.
                if self.isPrivate { wanted.forEach { self.allowOnce($0, origin: origin) } }
                else { wanted.forEach { SitePermissionStore.set(.allow, $0, for: origin) } }
                completion(true)
            case .once:
                wanted.forEach { self.allowOnce($0, origin: origin) }
                completion(true)
            case .never:
                // Remembered for the site, and for this tab even in a private window (no re-asking forever).
                wanted.forEach { self.denyHere($0, origin: origin) }
                if !self.isPrivate { wanted.forEach { SitePermissionStore.set(.deny, $0, for: origin) } }
                completion(false)
            case .dismissed:
                completion(false)
            case .decided(let allowed):
                completion(allowed)
            }
        }
    }

    /// The page learns its current notification permission when it loads.
    func announceNotificationPermission() {
        guard let webView, let origin = SitePermissionStore.origin(of: webView.url) else { return }
        let state: String
        switch SitePermissionStore.decision(.notifications, for: origin) {
        case .allow: state = "granted"
        case .deny: state = "denied"
        case nil: state = onceAllowed(.notifications, origin: origin) ? "granted" : "default"
        }
        webView.callAsyncJavaScript("window.__sheepNotifySet && window.__sheepNotifySet(state)", arguments: ["state": state],
                                    in: nil, in: .page, completionHandler: nil)
    }
}
