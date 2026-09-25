import WebKit

// Sound that starts on its own is refused on every page (see
// Tab.configuration), except on the sites where sound is the point. There a
// click on a song starts it a moment later, once the song has been fetched —
// by which time WebKit no longer counts it as coming from the click, refuses
// it, and the song only plays on the second or third click (25 Sep 2026).
//
// The policy is set per page, as the navigation is decided, through the one
// call Safari's own "Allow All Auto-Play" uses; it is outside the public
// framework, so it is asked for first, and a WebKit without it leaves the
// page as it was.
enum Autoplay {
    private static let listening = [
        "music.youtube.com", "youtube.com", "youtube-nocookie.com",
        "open.spotify.com", "soundcloud.com", "music.apple.com",
        "music.amazon.com", "tidal.com", "deezer.com", "pandora.com",
        "bandcamp.com", "twitch.tv", "mixcloud.com", "audiomack.com",
    ]

    static func allows(_ host: String) -> Bool {
        let host = host.lowercased()
        return listening.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// `_WKWebsiteAutoplayPolicy`: 0 default, 1 allow, 2 allow without sound, 3 deny.
    static func tune(_ preferences: WKWebpagePreferences, for host: String?) {
        guard let host, allows(host) else { return }
        let set = NSSelectorFromString("_setAutoplayPolicy:")
        guard preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, 1)
    }
}

extension Browser {
    /// WebKit asks this one when it is there, and the older one never; this
    /// sets the page's autoplay and hands the decision itself to the other.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        if action.targetFrame?.isMainFrame ?? true {
            Autoplay.tune(preferences, for: action.request.url?.host)
        }
        self.webView(webView, decidePolicyFor: action) { policy in
            decisionHandler(policy, preferences)
        }
    }
}
