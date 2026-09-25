import WebKit

// The ad blocker. No settings, no counter, no shield icon going green — it is
// compiled once at launch and then it is simply true that the page is lighter.
//
// A content rule list is enforced inside WebKit's networking, before a request
// is made and before a stylesheet is applied, so this costs nothing at run time
// in the way a JavaScript blocker does.

@MainActor
final class Shield: ObservableObject {
    static let shared = Shield()

    private(set) var list: WKContentRuleList?
    private var waiting: [WKUserContentController] = []

    /// Set the one time compiling the list didn't work. The toggle in
    /// Settings can say "on" all it wants; nothing is actually blocked until
    /// this is nil, so it is the one thing worth telling a person about
    /// rather than failing the quiet way a missing ad is quiet.
    @Published private(set) var trouble: String?

    /// On unless somebody said otherwise. Every tab's controller is told when
    /// this changes, so it takes effect on the next request rather than the
    /// next launch.
    var enabled = true

    /// Sites it is off for — the ones it broke. A checkout that never
    /// finishes, a video that never starts: switching off here, for this site,
    /// beats switching off everywhere and forgetting to switch back.
    private(set) var paused: Set<String> = Set(
        Store.settings.stringArray(forKey: "shield.paused") ?? []
    )

    func isPaused(on host: String?) -> Bool {
        guard let host else { return false }
        return paused.contains(host)
    }

    func pause(_ host: String, _ off: Bool) {
        if off { paused.insert(host) } else { paused.remove(host) }
        Store.settings.set(Array(paused).sorted(), forKey: "shield.paused")
    }

    /// Before each page: the list goes on or off for the site this tab is
    /// heading to. A rule list is enforced from the moment it is added, so
    /// doing this at the navigation is what makes "off for this site" true
    /// for the whole page rather than for the second half of it.
    func tune(_ controller: WKUserContentController, for host: String?) {
        guard let list else { return }
        controller.remove(list)
        if enabled, !isPaused(on: host) { controller.add(list) }
    }

    /// Third parties whose only job is to watch or to sell. First-party
    /// requests are untouched: a site's own scripts are the site.
    private static let unwanted = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "googletagservices.com", "google-analytics.com", "googletagmanager.com",
        "adservice.google.com", "amazon-adsystem.com", "adnxs.com", "adsrvr.org",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com",
        "smartadserver.com", "sharethrough.com", "indexww.com", "bidswitch.net",
        "33across.com", "teads.tv", "moatads.com", "adroll.com",
        "scorecardresearch.com", "quantserve.com", "chartbeat.com",
        "hotjar.com", "mouseflow.com", "fullstory.com", "clarity.ms",
        "mixpanel.com", "amplitude.com", "segment.com", "segment.io",
        "branch.io", "appsflyer.com", "adjust.com", "analytics.tiktok.com",
        "connect.facebook.net", "ads-twitter.com", "analytics.twitter.com",
        // Ad exchanges, networks and the pop-up and pop-under kind.
        "2mdn.net", "adform.net", "adformdn.com", "admob.com", "adcolony.com",
        "applovin.com", "vungle.com", "inmobi.com", "smaato.net", "media.net",
        "contextweb.com", "spotxchange.com", "spotx.tv", "springserve.com",
        "tremorhub.com", "lijit.com", "sovrn.com", "gumgum.com", "triplelift.com",
        "3lift.com", "sonobi.com", "emxdgt.com", "yieldmo.com", "yieldlab.net",
        "advertising.com", "zedo.com", "revcontent.com", "mgid.com", "adblade.com",
        "zergnet.com", "propellerads.com", "popads.net", "popcash.net",
        "adsterra.com", "exoclick.com", "trafficjunky.net", "juicyads.com",
        "hilltopads.net", "adcash.com", "onclickads.net", "clickadu.com",
        "bidvertiser.com", "infolinks.com", "adskeeper.com", "adskeeper.co.uk",
        "a-ads.com", "undertone.com", "conversantmedia.com", "dotomi.com",
        "yieldmanager.com", "ads.yahoo.com", "adtech.de", "serving-sys.com",
        "flashtalking.com", "innovid.com", "adsafeprotected.com", "doubleverify.com",
        "moatpixel.com", "adgrx.com", "simpli.fi", "steelhousemedia.com",
        "ads.linkedin.com", "ads.reddit.com", "ads.pinterest.com",
        // Data brokers and cross-site tracking.
        "mathtag.com", "turn.com", "rlcdn.com", "bluekai.com", "krxd.net",
        "everesttech.net", "agkn.com", "tapad.com", "crwdcntrl.net",
        "exelator.com", "eyeota.net", "liadm.com", "id5-sync.com",
        "media6degrees.com", "quantcount.com", "imrworldwide.com",
        "bat.bing.com", "ct.pinterest.com", "tr.snapchat.com", "mc.yandex.ru",
        "analytics.yahoo.com", "nr-data.net",
        // Session recorders and analytics that follow you across sites.
        "hotjar.io", "heapanalytics.com", "kissmetrics.com", "crazyegg.com",
        "luckyorange.com", "inspectlet.com", "smartlook.com",
    ]

    /// The few slots that are reliably an advertisement and nothing else. Kept
    /// deliberately short — a generous cosmetic list is how a blocker starts
    /// eating the page it was meant to clean.
    private static let slots = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^=\"google_ads_\"]",
        "[id^=\"div-gpt-ad\"]", "[id^=\"taboola-\"]", "#taboola-below-article",
        "iframe[src*=\"doubleclick.net\"]", "iframe[src*=\"googlesyndication\"]",
        "iframe[src*=\"amazon-adsystem\"]",
        "iframe[id^=\"google_ads_iframe\"]", "[id^=\"gpt-ad-\"]", "amp-ad",
        "amp-embed[type=\"taboola\"]", ".OUTBRAIN", "[data-widget-id^=\"outbrain\"]",
        "iframe[src*=\"adnxs.com\"]", "iframe[src*=\"criteo\"]",
        ".trc_rbox_container", ".mgid-widget",
    ]

    func compile() {
        guard list == nil else { return }
        trouble = nil
        var rules: [[String: Any]] = Shield.unwanted.map { domain in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": [
                    "url-filter": "^https?://([^/]+\\.)?\(escaped)",
                    "load-type": ["third-party"],
                ],
                "action": ["type": "block"],
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": Shield.slots.joined(separator: ", ")],
        ])

        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8)
        else {
            trouble = "Couldn't build the block list"
            return
        }

        guard let store = WKContentRuleListStore.default() else {
            trouble = "WebKit has nowhere to compile it"
            return
        }
        // Named after what is in it, so a list compiled at an earlier launch
        // is read back as it is — ready before the first page asks for it —
        // and compiled again only when the rules themselves change.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in json.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let name = "office-shield-\(String(hash, radix: 36))"
        store.lookUpContentRuleList(forIdentifier: name) { [weak self] kept, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let kept {
                    self.ready(kept)
                } else {
                    self.build(json, named: name, in: store)
                }
            }
        }
    }

    private func ready(_ compiled: WKContentRuleList) {
        list = compiled
        // Tabs that opened while this was still coming get it now.
        if enabled { waiting.forEach { $0.add(compiled) } }
        waiting = []
    }

    private func build(_ json: String, named name: String, in store: WKContentRuleListStore) {
        // Lists compiled from older rules, cleared out as the new one goes in.
        store.getAvailableContentRuleListIdentifiers { names in
            for old in names ?? [] where old.hasPrefix("office-shield") && old != name {
                store.removeContentRuleList(forIdentifier: old) { _ in }
            }
        }
        store.compileContentRuleList(
            forIdentifier: name,
            encodedContentRuleList: json
        ) { [weak self] compiled, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let compiled else {
                    self.trouble = error?.localizedDescription ?? "Compiling the block list failed"
                    return
                }
                self.ready(compiled)
            }
        }
    }

    /// Every tab asks for it; whoever asks before it is ready is remembered.
    func protect(_ controller: WKUserContentController) {
        if let list {
            if enabled { controller.add(list) }
        } else {
            waiting.append(controller)
        }
    }

    /// Switched on or off for every page that is already open.
    func apply(to controllers: [WKUserContentController]) {
        guard let list else { return }
        for controller in controllers {
            controller.remove(list)
            if enabled { controller.add(list) }
        }
    }
}
