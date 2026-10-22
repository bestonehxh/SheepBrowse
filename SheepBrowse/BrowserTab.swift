import AppKit
import WebKit

@MainActor
protocol BrowserTabDelegate: AnyObject {
    /// Title, URL, loading state, favicon or history buttons changed.
    func tabDidChange(_ tab: BrowserTab)
    /// The tab's web view was created or dropped (wake / sleep / crash).
    func tabWebViewDidChange(_ tab: BrowserTab)
    func tab(_ tab: BrowserTab, open url: URL, background: Bool)
    func tab(_ tab: BrowserTab, createWebViewWith configuration: WKWebViewConfiguration,
             for action: WKNavigationAction, features: WKWindowFeatures) -> WKWebView?
    /// The page called `window.close()`.
    func tabRequestsClose(_ tab: BrowserTab)
    /// The tab is the one on screen in its window (dialogs never come from a background tab).
    func tabIsSelected(_ tab: BrowserTab) -> Bool
    var window: NSWindow? { get }
}

/// One tab. While awake it owns a WKWebView; asleep it keeps only what it needs to come back — the URL,
/// title, favicon and WebKit's `interactionState` (back/forward list + scroll position) — and costs no
/// web content process.
final class BrowserTab: NSObject {
    let id = UUID()
    weak var delegate: BrowserTabDelegate?

    private(set) var webView: SheepWebView?
    private(set) var title: String
    private(set) var url: URL?
    private(set) var favicon: NSImage?
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var isSecure = false
    var lastActive = Date()
    var isPinned = false
    private(set) var isMuted = false
    private(set) var isPlayingAudio = false
    /// The page's certificate is one the user trusted (not macOS).
    var trustedCertificate = false
    /// A certificate problem on the page being opened (a card covers the page until answered).
    var certificateIssue: CertificateIssue?
    /// The main-frame URL being opened (before it commits).
    var pendingMainURL: URL?
    /// A private window's tab: its own data store, no history.
    let isPrivate: Bool

    private var savedState: Data?
    private var observations: [NSKeyValueObservation] = []
    /// A typed host that was given https:// by us: on a connection failure it is retried over http.
    private var upgradedFromTyped: URL?
    private var nextNavigationTyped = false
    /// Hosts whose camera/microphone request was answered in this tab.
    /// "Allow This Time" answers, by origin, until the tab closes.
    private var allowedOnce: [String: Set<SitePermission>] = [:]
    /// "Don't Allow" answers in this tab (a private window saves nothing, but must not be asked again and again).
    private var deniedOnce: [String: Set<SitePermission>] = [:]
    private(set) var cameraState: WKMediaCaptureState = .none
    private(set) var microphoneState: WKMediaCaptureState = .none
    /// Posted when any tab's camera/microphone state changes (the capture island listens).
    static let captureDidChange = Notification.Name("SheepBrowseCaptureDidChange")
    var isCapturing: Bool { cameraState != .none || microphoneState != .none }
    private var dialogShowing = false
    /// Page dialogs since the main frame last navigated: after 3 the page gets the default answers.
    private var dialogCount = 0
    /// One "open in another app" prompt per page.
    private var externalPromptShown = false
    /// The commit that is about to happen is the error page (not a visit for history).
    fileprivate(set) var committingErrorPage = false
    /// The address the error page on screen stands in for (nil when a real page is showing).
    private(set) var errorPageURL: URL?

    /// One of the app's own pages (sheep://downloads …), drawn natively.
    private(set) var internalPage: InternalPage?
    var isAsleep: Bool { webView == nil && url != nil && internalPage == nil }
    var isNewTabPage: Bool { url == nil && webView == nil }
    var canGoBack: Bool { webView?.canGoBack ?? false }
    var canGoForward: Bool { webView?.canGoForward ?? false }

    /// An empty new tab: no web view until something is loaded.
    init(isPrivate: Bool = false) {
        title = "New Tab"
        self.isPrivate = isPrivate
        super.init()
    }

    /// A restored tab: asleep until it is shown.
    init(saved: SavedTab, isPrivate: Bool = false) {
        title = saved.title
        isPinned = saved.pinned ?? false
        self.isPrivate = isPrivate
        url = saved.url.flatMap(URL.init(string:))
        savedState = saved.state
        super.init()
        favicon = FaviconCache.shared.image(for: url?.host)
        if let page = InternalPage(url: url) {
            internalPage = page
            favicon = page.icon
        }
    }

    /// A tab WebKit asked for (`window.open`, target=_blank): it must use WebKit's configuration.
    init(configuration: WKWebViewConfiguration, isPrivate: Bool) {
        title = "Loading…"
        self.isPrivate = isPrivate
        super.init()
        makeWebView(configuration: configuration)
    }

    var saved: SavedTab {
        let state = (webView?.interactionState as? Data) ?? savedState
        return SavedTab(url: url?.absoluteString, title: title, state: state, pinned: isPinned)
    }

    // MARK: Loading

    /// `upgraded`: the user typed a host without a scheme and it got https:// — only then may a refused
    /// connection be retried over http (never a TLS or certificate failure: that is what an attacker on
    /// the network would cause to downgrade the page).
    func load(_ target: URL, typed: Bool = false, upgraded: Bool = false) {
        if let page = InternalPage(url: target) { return show(page) }
        if internalPage != nil {
            internalPage = nil
            favicon = nil
        }
        if webView == nil { makeWebView(configuration: nil) }
        upgradedFromTyped = upgraded && target.scheme == "https" ? target : nil
        nextNavigationTyped = typed
        url = target
        webView?.load(URLRequest(url: target))
        delegate?.tabDidChange(self)
    }

    /// Shows one of the app's pages in this tab (the web view, if any, is closed).
    func show(_ page: InternalPage) {
        if webView != nil { close() }
        certificateIssue = nil
        pendingMainURL = nil
        internalPage = page
        url = page.url
        title = page.title
        favicon = page.icon
        isLoading = false
        savedState = nil
        delegate?.tabWebViewDidChange(self)
        delegate?.tabDidChange(self)
    }

    /// Creates the web view for a sleeping or restored tab and brings its page back.
    func wake() {
        guard webView == nil, url != nil, internalPage == nil else { return }
        makeWebView(configuration: nil)
        if let state = savedState {
            webView?.interactionState = state
            savedState = nil
        } else if let url {
            webView?.load(URLRequest(url: url))
        }
    }

    /// Drops the web view (and its web content process). Not while it plays media or uses the camera.
    func sleepIfIdle() {
        guard let webView, !isLoading,
              webView.cameraCaptureState == .none, webView.microphoneCaptureState == .none else { return }
        webView.requestMediaPlaybackState { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, state != .playing, self.webView === webView else { return }
                self.sleep()
            }
        }
    }

    private func sleep() {
        guard let webView else { return }
        savedState = webView.interactionState as? Data
        observations.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
        isLoading = false
        progress = 0
        delegate?.tabWebViewDidChange(self)
        delegate?.tabDidChange(self)
    }

    func close() {
        let wasCapturing = isCapturing
        cameraState = .none
        microphoneState = .none
        if wasCapturing { NotificationCenter.default.post(name: BrowserTab.captureDidChange, object: self) }
        webView?.stopLoading()
        observations.removeAll()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }

    private func makeWebView(configuration: WKWebViewConfiguration?) {
        let view = SheepWebView(frame: .zero, configuration: configuration ?? WebEngine.shared.makeConfiguration(isPrivate: isPrivate))
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.isInspectable = true
        view.tab = self
        webView = view

        func watch<Value>(_ keyPath: KeyPath<SheepWebView, Value>, _ update: @escaping @MainActor @Sendable (BrowserTab, WKWebView) -> Void) {
            observations.append(view.observe(keyPath, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    update(self, webView)
                    self.delegate?.tabDidChange(self)
                }
            })
        }
        watch(\.title) { tab, webView in
            if let title = webView.title, !title.isEmpty {
                tab.title = title
                if let url = webView.url, !tab.isPrivate, !tab.committingErrorPage { HistoryStore.shared.updateTitle(url: url, title: title) }
            }
        }
        watch(\.url) { tab, webView in
            if let url = webView.url { tab.url = url }
        }
        watch(\.isLoading) { tab, webView in tab.isLoading = webView.isLoading }
        watch(\.estimatedProgress) { tab, webView in tab.progress = webView.estimatedProgress }
        watch(\.hasOnlySecureContent) { tab, webView in tab.isSecure = webView.hasOnlySecureContent }
        watch(\.cameraCaptureState) { tab, webView in
            tab.cameraState = webView.cameraCaptureState
            NotificationCenter.default.post(name: BrowserTab.captureDidChange, object: tab)
        }
        watch(\.microphoneCaptureState) { tab, webView in
            tab.microphoneState = webView.microphoneCaptureState
            NotificationCenter.default.post(name: BrowserTab.captureDidChange, object: tab)
        }
        watch(\.canGoBack) { _, _ in }
        watch(\.canGoForward) { _, _ in }
        delegate?.tabWebViewDidChange(self)
    }

    // MARK: Audio

    /// Mutes every <video>/<audio> in the page now and any that starts later (WebKit has no public
    /// per-page mute; Web Audio is not covered).
    func setMuted(_ muted: Bool) {
        isMuted = muted
        let script = """
        window.__sheepMuted = muted;
        document.querySelectorAll('video, audio').forEach(m => { m.muted = muted; });
        if (!window.__sheepMuteHook) {
          window.__sheepMuteHook = true;
          document.addEventListener('play', e => { if (window.__sheepMuted) e.target.muted = true; }, true);
        }
        """
        // The app's own world: the page can neither see nor undo it.
        webView?.callAsyncJavaScript(script, arguments: ["muted": muted], in: nil, in: Self.muteWorld, completionHandler: nil)
        delegate?.tabDidChange(self)
    }

    private static let muteWorld = WKContentWorld.world(name: "SheepBrowseMute")

    /// Asks WebKit whether the page plays media (for the speaker in the tab).
    func pollAudio() {
        guard let webView else {
            if isPlayingAudio { isPlayingAudio = false; delegate?.tabDidChange(self) }
            return
        }
        webView.requestMediaPlaybackState { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard state == .playing else { return self.setPlayingAudio(false) }
                // Playing is not audible: a muted autoplay video must not show the speaker (Chrome's rule).
                let script = "return [...document.querySelectorAll('video, audio')].some(m => !m.paused && !m.muted && m.volume > 0 && m.readyState > 2);"
                webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
                    MainActor.assumeIsolated {
                        if case .success(let value) = result { self?.setPlayingAudio(value as? Bool ?? false) }
                    }
                }
            }
        }
    }

    private func setPlayingAudio(_ playing: Bool) {
        guard playing != isPlayingAudio else { return }
        isPlayingAudio = playing
        delegate?.tabDidChange(self)
    }

    // MARK: Page actions

    func zoom(_ direction: Int) {
        guard let webView else { return }
        let steps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
        let current = webView.pageZoom
        let next: CGFloat
        switch direction {
        case 0: next = 1
        case 1...: next = steps.first { $0 > current + 0.001 } ?? steps.last!
        default: next = steps.last { $0 < current - 0.001 } ?? steps.first!
        }
        webView.pageZoom = next
        if !isPrivate { Settings.setZoom(next, for: url?.host) }
        delegate?.tabDidChange(self)
    }

    private func fetchFavicon() {
        guard let webView, let pageURL = webView.url, let host = pageURL.host else { return }
        if let cached = FaviconCache.shared.image(for: host), favicon !== cached {
            favicon = cached
            delegate?.tabDidChange(self)
        }
        let script = """
        return [...document.querySelectorAll('link[rel~="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"]')]
          .map(l => [l.href, (l.sizes && l.sizes.value) || '', l.rel || '']);
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                var candidates: [(URL, Int)] = []
                if case .success(let value) = result, let links = value as? [[String]] {
                    for link in links where link.count == 3 {
                        guard let href = URL(string: link[0]), href.scheme?.hasPrefix("http") == true else { continue }
                        // Prefer a 32–64 px icon; then larger; an SVG decodes at any size.
                        let size = Int(link[1].split(separator: "x").first ?? "") ?? (href.pathExtension == "svg" ? 48 : 16)
                        let rank = size >= 32 && size <= 64 ? 0 : size > 64 ? 1 : 2
                        candidates.append((href, rank * 1000 + abs(size - 32)))
                    }
                }
                var urls = candidates.sorted { $0.1 < $1.1 }.map(\.0)
                if let root = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL { urls.append(root) }
                // The app fetches these itself (outside WebKit): only the page's own server, or https on a
                // public host — a page must not make the app call into the LAN or localhost.
                urls = urls.filter { $0.host == host || ($0.scheme == "https" && !AddressInput.isLocal($0.host)) }
                FaviconCache.shared.fetch(host: host, candidates: urls, persist: !self.isPrivate) { [weak self] image in
                    guard let self, self.url?.host == host else { return }
                    self.favicon = image
                    self.delegate?.tabDidChange(self)
                    if !self.isPrivate { SessionStore.scheduleSave() }
                }
            }
        }
    }
}

// MARK: - Navigation

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        let target = navigationAction.request.url
        let scheme = target?.scheme?.lowercased() ?? ""
        let isMain = navigationAction.targetFrame?.isMainFrame ?? true

        // ⌘-click / middle-click a link: a background tab (⇧ brings it to the front), as in Chrome.
        if navigationAction.navigationType == .linkActivated, let target, ["http", "https"].contains(scheme),
           navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 2 {
            delegate?.tab(self, open: target, background: !navigationAction.modifierFlags.contains(.shift))
            return (.cancel, preferences)
        }
        // The error page's Try Again (a link, so it works without the page's scripts): load the real address.
        // Reloading would only show the stand-in page again. Anything else asking for it gets nothing.
        if scheme == ErrorPage.retryScheme {
            if isMain, errorPageURL != nil { DispatchQueue.main.async { self.reload() } }
            return (.cancel, preferences)
        }
        // A top-level data: page could pose as any site (its address reads like one) — never, as in Chrome.
        if scheme == "data" && isMain { return (.cancel, preferences) }
        // A web page may not open local files; a file the user opened (Open With) may link to its neighbours.
        if scheme == "file" && webView.url != nil && webView.url?.scheme != "file" { return (.cancel, preferences) }
        if isMain {
            pendingMainURL = target
            certificateIssue = nil
            dialogCount = 0
            externalPromptShown = false
        }

        if ["http", "https", "about", "blob", "data", "file"].contains(scheme) || scheme.isEmpty {
            return (.allow, preferences)
        }

        // mailto:, tel:, zoommtg:, … — another app opens it, after the user agrees (a page cannot launch
        // apps on its own). Network-mount schemes are refused outright (smb:// would mount the attacker's
        // share and send the Mac's credentials); one prompt per page.
        let refused = ["smb", "afp", "nfs", "cifs", "ftp", "ftps", "webdav", "davs", "vnc", "x-apple.systempreferences"]
        if isMain, let target, scheme != "javascript", !refused.contains(scheme), !externalPromptShown {
            externalPromptShown = true
            let host = webView.url?.host ?? "This page"
            let app = NSWorkspace.shared.urlForApplication(toOpen: target)
            let appName = app.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            let shown = target.absoluteString.count > 120 ? String(target.absoluteString.prefix(120)) + "…" : target.absoluteString
            if let appName, await confirm(message: "Open “\(appName)”?",
                                          info: "\(host) wants to open this link in another app:\n\(shown)", ok: "Open") {
                NSWorkspace.shared.open(target)
            }
        }
        return (.cancel, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame && !navigationResponse.canShowMIMEType { return .download }
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.track(download, window: delegate?.window, isPrivate: isPrivate)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.track(download, window: delegate?.window, isPrivate: isPrivate)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let committed = webView.url else { return }
        url = committed
        pendingMainURL = nil
        trustedCertificate = {
            guard committed.scheme == "https", let host = committed.host, let trust = webView.serverTrust,
                  let fingerprint = CertificateTrust.fingerprint(of: trust) else { return false }
            let server = CertificateTrust.serverKey(host: host, port: committed.port ?? 443)
            return CertificateTrust.pinned(server) == fingerprint || CertificateTrust.isAllowedOnce(fingerprint, for: server)
        }()
        if let upgraded = upgradedFromTyped, upgraded.host != committed.host { upgradedFromTyped = nil }
        if !isPrivate && !committingErrorPage {
            HistoryStore.shared.recordVisit(url: committed, title: webView.title, typed: nextNavigationTyped)
        }
        errorPageURL = committingErrorPage ? committed : nil
        // Until the new page names itself (some never do): its host, not the previous page's title.
        title = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? committed.host ?? committed.absoluteString
        committingErrorPage = false
        nextNavigationTyped = false
        let zoom = isPrivate ? webView.pageZoom : Settings.zoom(for: committed.host)
        if abs(webView.pageZoom - zoom) > 0.001 { webView.pageZoom = zoom }
        favicon = FaviconCache.shared.image(for: committed.host)
        delegate?.tabDidChange(self)
        if !isPrivate { SessionStore.scheduleSave() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        announceNotificationPermission()
        upgradedFromTyped = nil
        fetchFavicon()
        if !isPrivate { SessionStore.scheduleSave() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return } // frame load interrupted (download)
        let failing = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url

        // A typed "example.com" got https:// first; a server that only speaks http gets a second try.
        if let upgraded = upgradedFromTyped, let failing, failing.host == upgraded.host,
           nsError.domain == NSURLErrorDomain,
           // Only "nothing listens on 443". A TLS or certificate failure is what a network attacker would
           // produce to push the page to http — that shows the error page (or the certificate card).
           nsError.code == NSURLErrorCannotConnectToHost,
           var components = URLComponents(url: failing, resolvingAgainstBaseURL: false) {
            upgradedFromTyped = nil
            components.scheme = "http"
            if let http = components.url {
                webView.load(URLRequest(url: http))
                return
            }
        }
        upgradedFromTyped = nil
        guard let failing, certificateIssue == nil else { return }
        committingErrorPage = true
        webView.loadSimulatedRequest(URLRequest(url: failing), responseHTML: ErrorPage.html(for: nsError, url: failing))
    }

    /// Reload (⌘R, the toolbar, Try Again). On an error page, a fresh load of the address it stands in for.
    func reload() {
        guard let webView else {
            if let url { load(url) }
            return
        }
        if let failed = errorPageURL {
            errorPageURL = nil
            webView.load(URLRequest(url: failed))
        } else {
            webView.reload()
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page's process died (memory pressure or a crash): reload it, as Safari does.
        webView.reload()
    }
}

// MARK: - Windows, dialogs, permissions

extension BrowserTab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        delegate?.tab(self, createWebViewWith: configuration, for: navigationAction, features: windowFeatures)
    }

    func webViewDidClose(_ webView: WKWebView) {
        delegate?.tabRequestsClose(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        _ = await showDialog(message: message, frame: frame, buttons: ["OK"])
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await showDialog(message: message, frame: frame, buttons: ["OK", "Cancel"]) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        let answer = await showDialog(message: prompt, frame: frame, buttons: ["OK", "Cancel"], accessory: field)
        return answer == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard let window = delegate?.window else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.urls : nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        let wanted: [SitePermission]
        switch type {
        case .camera: wanted = [.camera]
        case .microphone: wanted = [.microphone]
        default: wanted = [.camera, .microphone]
        }
        guard let site = SitePermissionStore.origin(origin) else { return .deny }
        return await ask(wanted, origin: site)
    }

    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo) async -> WKPermissionDecision {
        guard let site = SitePermissionStore.origin(origin) else { return .deny }
        return await ask([.location], origin: site)
    }

    private func ask(_ wanted: [SitePermission], origin: String) async -> WKPermissionDecision {
        await withCheckedContinuation { continuation in
            requestPermissions(wanted, origin: origin) { continuation.resume(returning: $0 ? .grant : .deny) }
        }
    }

    #if DEBUG
    /// Screenshots of the capture island without a camera.
    func debugFakeCapture() {
        cameraState = .active
        microphoneState = .muted
        NotificationCenter.default.post(name: BrowserTab.captureDidChange, object: self)
    }
    #endif

    func onceAllowed(_ permission: SitePermission, origin: String) -> Bool {
        allowedOnce[origin]?.contains(permission) ?? false
    }

    func allowOnce(_ permission: SitePermission, origin: String) {
        allowedOnce[origin, default: []].insert(permission)
    }

    func denyHere(_ permission: SitePermission, origin: String) {
        deniedOnce[origin, default: []].insert(permission)
        allowedOnce[origin]?.remove(permission)
    }

    func deniedHere(_ permission: SitePermission, origin: String) -> Bool {
        deniedOnce[origin]?.contains(permission) ?? false
    }

    /// Settings changed for `origin`: forget this tab's own answers for it, stop capture that is no longer
    /// allowed, and tell the page its notification permission again.
    func sitePermissionsChanged(for origin: String, permission: SitePermission) {
        allowedOnce[origin]?.remove(permission)
        deniedOnce[origin]?.remove(permission)
        guard SitePermissionStore.origin(of: url) == origin else { return }
        let allowed = SitePermissionStore.decision(permission, for: origin) == .allow
        if permission == .camera, cameraState != .none, !allowed { setCapture(camera: WKMediaCaptureState.none) }
        if permission == .microphone, microphoneState != .none, !allowed { setCapture(microphone: WKMediaCaptureState.none) }
        if permission == .notifications { announceNotificationPermission() }
    }

    /// Stops or mutes the page's capture (the island and the address bar buttons).
    func setCapture(camera: WKMediaCaptureState? = nil, microphone: WKMediaCaptureState? = nil) {
        if let camera { webView?.setCameraCaptureState(camera, completionHandler: nil) }
        if let microphone { webView?.setMicrophoneCaptureState(microphone, completionHandler: nil) }
    }

    /// One page dialog at a time per tab; a page that keeps asking while one is up gets the default answer.
    private func showDialog(message: String, frame: WKFrameInfo, buttons: [String],
                            accessory: NSView? = nil) async -> NSApplication.ModalResponse {
        guard let window = delegate?.window, !dialogShowing, delegate?.tabIsSelected(self) == true,
              dialogCount < 3 else { return .alertSecondButtonReturn }
        dialogShowing = true
        dialogCount += 1
        defer { dialogShowing = false }
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says" : "\(host) says"
        alert.informativeText = String(message.prefix(2000))
        for title in buttons { alert.addButton(withTitle: title) }
        alert.accessoryView = accessory
        if let accessory { alert.window.initialFirstResponder = accessory }
        return await alert.beginSheetModal(for: window)
    }

    func confirm(message: String, info: String, ok: String) async -> Bool {
        guard let window = delegate?.window, !dialogShowing else { return false }
        dialogShowing = true
        defer { dialogShowing = false }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: "Cancel")
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }
}

// MARK: - Web view

final class SheepWebView: WKWebView {
    weak var tab: BrowserTab?
    /// Set when the user picked "Open Link in New Tab" in the context menu; read by createWebViewWith.
    static var contextMenuNewTabAt: Date?
    private var menuObserver: NSObjectProtocol?

    /// WebKit's "Open Link in New Window" opens a tab here, so it is called that. Only the title changes:
    /// WebKit reads the item's representedObject as its own, and replacing the item breaks it.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierOpenLinkInNewWindow": item.title = "Open Link in New Tab"
            case "WKMenuItemIdentifierOpenImageInNewWindow": item.title = "Open Image in New Tab"
            case "WKMenuItemIdentifierOpenMediaInNewWindow": item.title = "Open Video in New Tab"
            default: break
            }
        }
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.willSendActionNotification, object: menu,
                                                              queue: .main) { note in
            let title = (note.userInfo?["MenuItem"] as? NSMenuItem)?.title ?? ""
            MainActor.assumeIsolated {
                if title.hasSuffix("in New Tab") { SheepWebView.contextMenuNewTabAt = Date() }
            }
        }
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        DispatchQueue.main.async { [weak self] in
            if let observer = self?.menuObserver { NotificationCenter.default.removeObserver(observer) }
            self?.menuObserver = nil
        }
    }
}

// MARK: - Error page

enum ErrorPage {
    /// Try Again's link (handled by the tab's navigation policy; never reaches the network).
    static let retryScheme = "sheep-retry"

    private enum Kind { case offline, notFound, refused, slow, insecure, other }

    static func html(for error: NSError, url: URL) -> String {
        let host = escape(url.host ?? url.absoluteString)
        let (kind, title, detail): (Kind, String, String) = {
            switch error.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
                return (.offline, "You’re not connected to the internet", "Check your Wi-Fi or network cable. This page will try again when you’re back online.")
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return (.notFound, "Can’t find this server", "The address could not be found. Check the spelling, or that the device is on this network.")
            case NSURLErrorTimedOut:
                return (.slow, "The server took too long", "The site may be down, or your connection may be slow.")
            case NSURLErrorCannotConnectToHost:
                return (.refused, "Can’t connect to this server", "The server refused the connection. It may be turned off, or not serving web pages on this port.")
            case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid, NSURLErrorSecureConnectionFailed:
                return (.insecure, "This connection is not private", "The server did not present a certificate this Mac trusts. Someone could be pretending to be the site.")
            default:
                return (.other, "Can’t open this page", escape(error.localizedDescription))
            }
        }()
        // SF Symbols-like glyphs (wifi.slash, globe, bolt.horizontal, clock, lock, exclamationmark.triangle).
        let (glyph, tint): (String, String) = {
            switch kind {
            case .offline: return (#"<path d="M4 12.5Q16 2 28 12.5M8.3 17Q16 10.5 23.7 17M12.6 21.4Q16 18.8 19.4 21.4"/><circle cx="16" cy="25.4" r="1.7" fill="currentColor" stroke="none"/><path d="M6 5 26 27"/>"#, "#ff9f0a")
            case .notFound: return (#"<circle cx="16" cy="16" r="11.5"/><ellipse cx="16" cy="16" rx="4.8" ry="11.5"/><path d="M4.5 16h23M6.5 10h19M6.5 22h19"/>"#, "#0a84ff")
            case .refused: return (#"<path d="M11 5v6M21 5v6M8 11h16v4a8 8 0 0 1-16 0zM16 23v4"/><path d="M5 5l22 22"/>"#, "#ff9f0a")
            case .slow: return (#"<circle cx="16" cy="16" r="11.5"/><path d="M16 9v7l4.5 3"/>"#, "#ffd60a")
            case .insecure: return (#"<rect x="8.5" y="14" width="15" height="12" rx="3"/><path d="M11.5 14v-3.5a4.5 4.5 0 0 1 9 0V14"/><path d="M16 18.5v3"/>"#, "#ff453a")
            case .other: return (#"<path d="M16 4.5 28.5 26.5h-25z"/><path d="M16 12.5v6.5"/><circle cx="16" cy="22.6" r="1.4" fill="currentColor" stroke="none"/>"#, "#98989d")
            }
        }()
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <meta name="viewport" content="width=device-width"><title>\(title)</title>
        <style>
        :root{--tint:\(tint)}
        *{box-sizing:border-box}
        html,body{height:100%;margin:0}
        body{font:14px -apple-system,system-ui,sans-serif;display:grid;place-items:center;background:Canvas;color:CanvasText;
             -webkit-user-select:none;user-select:none;cursor:default;padding:24px}
        .card{width:min(440px,100%);padding:36px 32px 26px;text-align:center;border-radius:28px;
              background:color-mix(in srgb,CanvasText 4%,Canvas);border:1px solid color-mix(in srgb,CanvasText 9%,transparent);
              box-shadow:0 18px 50px -20px rgba(0,0,0,.35)}
        .tile{width:72px;height:72px;margin:0 auto 20px;border-radius:20px;display:grid;place-items:center;color:var(--tint);
              background:color-mix(in srgb,var(--tint) 16%,transparent);
              box-shadow:inset 0 1px 0 color-mix(in srgb,white 18%,transparent)}
        .tile svg{width:36px;height:36px;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
        h1{font-size:21px;font-weight:650;letter-spacing:-.01em;margin:0 0 8px}
        .host{display:inline-block;max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;margin:0 0 14px;
              padding:3px 11px;border-radius:999px;font:500 12.5px ui-monospace,SFMono-Regular,Menlo,monospace;
              background:color-mix(in srgb,CanvasText 7%,transparent);color:color-mix(in srgb,CanvasText 75%,transparent)}
        p{color:color-mix(in srgb,CanvasText 58%,transparent);line-height:1.5;margin:0 0 24px;font-size:13.5px}
        .btn{display:inline-flex;align-items:center;gap:7px;padding:9px 22px;border-radius:999px;text-decoration:none;font-weight:600;
             color:white;background:AccentColor;
             box-shadow:inset 0 1px 0 rgba(255,255,255,.25),0 4px 14px -6px AccentColor;transition:transform .12s,filter .12s}
        .btn:hover{filter:brightness(1.08)} .btn:active{transform:scale(.96)}
        .btn svg{width:14px;height:14px;fill:none;stroke:currentColor;stroke-width:2.4;stroke-linecap:round;stroke-linejoin:round}
        .btn.busy svg{animation:spin .8s linear infinite} @keyframes spin{to{transform:rotate(360deg)}}
        .code{margin-top:20px;font-size:11px;color:color-mix(in srgb,CanvasText 35%,transparent)}
        </style></head><body><div class="card">
        <div class="tile"><svg viewBox="0 0 32 32">\(glyph)</svg></div>
        <h1>\(title)</h1><div class="host">\(host)</div><p>\(detail)</p>
        <a class="btn" id="retry" href="\(retryScheme):"><svg viewBox="0 0 16 16"><path d="M13.5 8a5.5 5.5 0 1 1-1.8-4.1"/><path d="M12.2 1.6v3h-3"/></svg>Try Again</a>
        <div class="code">\(escape(error.domain)) \(error.code)</div>
        </div><script>
        const retry = document.getElementById('retry');
        const go = () => { retry.classList.add('busy'); location.href = '\(retryScheme):'; };
        retry.addEventListener('click', e => { e.preventDefault(); go(); });
        addEventListener('keydown', e => { if (e.key === 'Enter') go(); });
        \(kind == .offline ? "addEventListener('online', go);" : "")
        </script></body></html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
