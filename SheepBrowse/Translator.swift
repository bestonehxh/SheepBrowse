import AppKit
import Combine
import SwiftUI
import Translation
import WebKit

/// Translates the page with Apple's on-device Translation framework (nothing leaves the Mac). The page's
/// text nodes are collected in the app's own content world, translated in batches, and written back;
/// "Show Original" puts the saved text back.
enum PageTranslator {
    static let world = WKContentWorld.world(name: "SheepBrowseTranslate")

    /// The user's language (the first preferred one).
    static var targetLanguage: Locale.Language {
        Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    }

    static func translate(_ webView: WKWebView, in controller: BrowserWindowController) {
        Task { @MainActor in
            let translated = (try? await webView.callAsyncJavaScript("return !!window.__sheepTranslated;", contentWorld: world)) as? Bool ?? false
            if translated {
                _ = try? await webView.callAsyncJavaScript("window.__sheepRestore && window.__sheepRestore(); return 0;", contentWorld: world)
                return
            }
            guard let texts = try? await webView.callAsyncJavaScript(collectScript, contentWorld: world) as? [String], !texts.isEmpty else { return }
            guard let host = controller.translationHost() else { return }
            host.model.run(texts: texts, target: targetLanguage) { results in
                let list = results.map { $0 ?? NSNull() as Any }
                webView.callAsyncJavaScript("window.__sheepApply(list); return 0;", arguments: ["list": list], in: nil,
                                            in: world, completionHandler: nil)
            }
        }
    }

    /// Text nodes worth translating (not code, inputs or hidden UI), saved so they can be restored.
    static let collectScript = #"""
    const skip = new Set(['SCRIPT','STYLE','NOSCRIPT','CODE','PRE','TEXTAREA','INPUT','SELECT','SVG','MATH','KBD','SAMP','VAR']);
    const nodes = [];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode(n) {
        const t = n.nodeValue;
        if (!t || !/\p{L}/u.test(t) || t.trim().length < 2) return NodeFilter.FILTER_REJECT;
        for (let e = n.parentElement; e; e = e.parentElement) {
          if (skip.has(e.tagName) || e.isContentEditable || e.getAttribute('translate') === 'no' || e.classList.contains('notranslate'))
            return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    while (walker.nextNode() && nodes.length < 4000) nodes.push(walker.currentNode);
    window.__sheepNodes = nodes;
    window.__sheepOriginals = nodes.map(n => n.nodeValue);
    window.__sheepApply = list => {
      list.forEach((text, i) => {
        const n = window.__sheepNodes[i];
        if (!n || text == null) return;
        const original = window.__sheepOriginals[i];
        const lead = original.match(/^\s*/)[0], trail = original.match(/\s*$/)[0];
        n.nodeValue = lead + text.trim() + trail;
      });
      window.__sheepTranslated = true;
    };
    window.__sheepRestore = () => {
      (window.__sheepNodes || []).forEach((n, i) => { n.nodeValue = window.__sheepOriginals[i]; });
      window.__sheepTranslated = false;
    };
    return nodes.map(n => n.nodeValue.trim());
    """#
}

/// The Translation framework hands out sessions through SwiftUI; this invisible view owns one per window.
@MainActor
final class TranslationModel: ObservableObject {
    typealias Completion = @MainActor @Sendable ([String?]) -> Void
    @Published var configuration: TranslationSession.Configuration?
    private var pending: (texts: [String], completion: Completion)?

    func run(texts: [String], target: Locale.Language, completion: @escaping Completion) {
        pending = (texts, completion)
        if configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: nil, target: target)
        }
    }

    private func takeJob() -> (texts: [String], completion: Completion)? {
        defer { pending = nil }
        return pending
    }

    nonisolated func perform(with session: TranslationSession) async {
        nonisolated(unsafe) let session = session
        guard let job = await takeJob() else { return }
        var results = [String?](repeating: nil, count: job.texts.count)
        do {
            try await session.prepareTranslation()
            // Batches keep the page updating while a long page is still being translated.
            for start in stride(from: 0, to: job.texts.count, by: 200) {
                let batch = (start..<min(start + 200, job.texts.count)).map {
                    TranslationSession.Request(sourceText: job.texts[$0], clientIdentifier: String($0))
                }
                for response in try await session.translations(from: batch) {
                    if let id = response.clientIdentifier.flatMap(Int.init) { results[id] = response.targetText }
                }
                let snapshot = results
                await job.completion(snapshot)
            }
        } catch {
            NSLog("SheepBrowse: translation failed: \(error)")
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "This page could not be translated"
                alert.informativeText = "Its language may not be supported, or the language pack is not downloaded (System Settings ▸ General ▸ Language & Region ▸ Translation Languages)."
                alert.runModal()
            }
        }
    }
}

struct TranslationHostView: View {
    @ObservedObject var model: TranslationModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(model.configuration) { session in
                nonisolated(unsafe) let session = session
                await model.perform(with: session)
            }
    }
}

final class TranslationHost: NSHostingView<TranslationHostView> {
    let model: TranslationModel

    init() {
        let model = TranslationModel()
        self.model = model
        super.init(rootView: TranslationHostView(model: model))
    }

    @MainActor required init(rootView: TranslationHostView) { fatalError() }
    required init?(coder: NSCoder) { fatalError() }
}

extension BrowserWindowController {
    /// The window's (invisible) translation host, created on first use.
    func translationHost() -> TranslationHost? {
        guard let root = window?.contentView else { return nil }
        if let host = root.subviews.compactMap({ $0 as? TranslationHost }).first { return host }
        let host = TranslationHost()
        host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        root.addSubview(host, positioned: .below, relativeTo: nil)
        return host
    }
}
