import Foundation

/// The built-in ad and tracker blocker: a WebKit content rule list (blocked inside the engine, before a
/// request is made). Third-party loads from known ad/tracking hosts are blocked; a few common ad
/// containers are hidden. Kept deliberately conservative — nothing a sign-in or a video player needs.
enum ContentBlocker {
    static let blockedHosts: [String] = [
        // Google ad serving and measurement (not Google sign-in, Maps, YouTube or Fonts)
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "googletagservices.com",
        "adservice.google.com", "google-analytics.com", "pagead2.googlesyndication.com",
        // Ad exchanges and networks
        "amazon-adsystem.com", "adnxs.com", "adsrvr.org", "advertising.com", "criteo.com", "criteo.net",
        "taboola.com", "outbrain.com", "pubmatic.com", "rubiconproject.com", "openx.net", "casalemedia.com",
        "smartadserver.com", "adform.net", "yieldmo.com", "teads.tv", "sharethrough.com", "3lift.com",
        "indexww.com", "bidswitch.net", "contextweb.com", "sonobi.com", "media.net", "zemanta.com",
        "revcontent.com", "mgid.com", "lijit.com", "sovrn.com", "adcolony.com", "applovin.com",
        "popads.net", "propellerads.com", "popcash.net", "exoclick.com", "juicyads.com", "adskeeper.com",
        "admixer.net", "zedo.com", "spotxchange.com", "springserve.com", "serving-sys.com",
        "flashtalking.com", "innovid.com", "ads.yahoo.com", "ads-twitter.com", "ads.linkedin.com",
        "an.yandex.ru", "adriver.ru", "yieldlab.net", "smaato.net", "inmobi.com", "adsafeprotected.com",
        "doubleverify.com", "moatads.com", "adition.com", "gumgum.com", "33across.com", "onetag-sys.com",
        // Trackers
        "scorecardresearch.com", "quantserve.com", "mathtag.com", "rlcdn.com", "demdex.net",
        "everesttech.net", "krxd.net", "bluekai.com", "exelator.com", "agkn.com", "hotjar.com",
        "mouseflow.com", "crazyegg.com", "clarity.ms", "analytics.tiktok.com", "mc.yandex.ru",
        "bat.bing.com", "cdn.mxpnl.com", "fullstory.com", "luckyorange.com", "tapad.com", "adsymptotic.com",
    ]

    /// Ad containers hidden on every page (only ones that hold nothing but ads).
    static let hiddenSelectors = [
        "ins.adsbygoogle", "[id^=\"div-gpt-ad\"]", "[id^=\"google_ads_iframe\"]", "iframe[src*=\"doubleclick.net\"]",
        ".trc_rbox_container", ".OUTBRAIN", "[data-google-query-id]",
    ].joined(separator: ", ")

    static func rulesJSON(allowing allowedSites: Set<String>) -> String {
        var rules: [[String: Any]] = blockedHosts.map { host in
            let escaped = host.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": ["url-filter": "^[^:]+://+([^:/]+\\.)?\(escaped)[:/]", "load-type": ["third-party"]],
                "action": ["type": "block"],
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": hiddenSelectors],
        ])
        if !allowedSites.isEmpty {
            rules.append([
                "trigger": ["url-filter": ".*", "if-domain": allowedSites.sorted().map { "*" + $0 }],
                "action": ["type": "ignore-previous-rules"],
            ])
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
