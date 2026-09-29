//
//  BrowserBlocker.swift
//  Nidus
//
//  Reads every tab of a running browser in one Apple Event and points the
//  blocked ones at a local block page. Browsers send no navigation events, so
//  the owner calls sweep() on a timer while a session runs.
//
//  Restore never needs to remember a tab: the block page's URL carries the
//  original (`blocked.html?u=<original>`), so a sweep for block-page URLs finds
//  every tab to put back, however the user has reordered or closed tabs since.
//  That matters for Safari, whose tabs have no `id`.
//

import Foundation

/// The scripting vocabulary of one browser. Chromium browsers do not share
/// codes: Chrome's tab class is `CrTb`, Opera's is `OpTb`. Each entry here was
/// read from the app's own .sdef; add a browser only after reading its.
struct BrowserProfile: Sendable, Hashable {
    let name: String
    let bundleID: String
    let tabClass: String
    let urlProperty: String

    static let safari = BrowserProfile(name: "Safari", bundleID: "com.apple.Safari", tabClass: "bTab", urlProperty: "pURL")
    static let chrome = BrowserProfile(name: "Google Chrome", bundleID: "com.google.Chrome", tabClass: "CrTb", urlProperty: "URL ")
    static let operaAir = BrowserProfile(name: "Opera Air", bundleID: "com.operasoftware.OperaAir", tabClass: "OpTb", urlProperty: "URL ")

    static let known: [BrowserProfile] = [.safari, .chrome, .operaAir]
}

/// One tab, addressed the only way every browser supports: its window's id
/// and its 1-based index in that window.
struct TabLocation: Sendable, Hashable {
    let windowID: Int
    let index: Int
    let url: String
}

/// The local page blocked tabs are sent to, and the round trip of the
/// original URL through its query string: `blocked.html?g=<goal>&m=<minutes>&u=<original>`.
struct BlockPage: Sendable {
    let fileURL: URL
    /// The folder name Nidus began with. The Snooze link is `nidus://snooze`.
    let dropletID: String

    init(directory: URL, dropletID: String = "focus") {
        fileURL = directory.appendingPathComponent("blocked.html")
        self.dropletID = dropletID
    }

    /// Writes the page. Call at activation; it lives in Nidus's folder in
    /// Application Support, never in the app, whose signature must not change.
    func install() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let html = Self.html.replacingOccurrences(of: "{{DROPLET}}", with: dropletID)
        try Data(html.utf8).write(to: fileURL, options: .atomic)
    }

    /// `snoozeKey` is what the page's Snooze link asks Nidus to let
    /// through: the list entry that matched, so `m.youtube.com` snoozes
    /// `youtube.com`.
    func url(blocking original: String, goal: String = "", snoozeMinutes: Int = 3, snoozeKey: String = "") -> String {
        fileURL.absoluteString
            + "?g=" + Self.encode(goal)
            + "&m=\(snoozeMinutes)"
            + "&s=" + Self.encode(snoozeKey)
            + "&u=" + Self.encode(original)
    }

    /// The URL a block-page tab was showing before, or nil for any other URL.
    func original(from url: String) -> String? {
        guard let components = URLComponents(string: url), components.scheme == "file",
              components.path == fileURL.path else { return nil }
        return components.queryItems?.first(where: { $0.name == "u" })?.value
    }

    /// Everything but the unreserved characters, so `&`, `=`, `+` and `#` in
    /// a goal or an original URL can never break the query apart.
    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static let html = """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="color-scheme" content="light dark">
    <title>Blocked by Nidus</title>
    <style>
    /* Solanum: ivory and slate, hairlines not shadows, clay as a fill only. */
    :root { --page: #faf9f5; --raised: #ffffff; --ink: #141413; --muted: #5e5d59; --faint: #73726c;
            --hairline: rgba(31, 30, 29, .15); --strong: rgba(31, 30, 29, .3); --well: rgba(31, 30, 29, .06); }
    @media (prefers-color-scheme: dark) {
      :root { --page: #141413; --raised: #262625; --ink: #faf9f5; --muted: #b0aea5; --faint: #91918d;
              --hairline: rgba(250, 249, 245, .18); --strong: rgba(250, 249, 245, .32); --well: rgba(250, 249, 245, .08); }
    }
    * { box-sizing: border-box; }
    html, body { height: 100%; margin: 0; }
    body { display: grid; place-items: center; background: var(--page); color: var(--ink);
           font: 15px/23px -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
    main { width: min(480px, calc(100vw - 48px)); padding: 48px 0; }
    .icon { display: block; width: 56px; height: 56px; margin-bottom: 32px; }
    .overline { font: 11px/16px ui-monospace, "SF Mono", Menlo, monospace; letter-spacing: .08em; text-transform: uppercase;
                color: var(--faint); margin: 0 0 12px; }
    h1 { font: 400 32px/38px "New York", ui-serif, "Iowan Old Style", Georgia, serif; margin: 0 0 8px; }
    p { margin: 0; }
    p.lede { color: var(--muted); }
    .goal { margin-top: 32px; padding: 16px 20px 18px; background: var(--raised); border: 1px solid var(--hairline); border-radius: 12px; }
    .goal .overline { color: var(--muted); margin-bottom: 6px; }
    .goal div { font: 400 24px/31px "New York", ui-serif, "Iowan Old Style", Georgia, serif; overflow-wrap: anywhere; }
    .actions { margin-top: 24px; }
    a.snooze { display: inline-block; padding: 7px 14px; background: var(--raised); border: 1px solid var(--strong);
               border-radius: 8px; color: var(--ink); text-decoration: none; font-weight: 500; font-size: 14px; line-height: 20px; }
    a.snooze:hover { background: var(--well); }
    a.snooze:focus-visible { outline: 2px solid var(--strong); outline-offset: 2px; }
    .fine { margin-top: 48px; font: 11px/16px ui-monospace, "SF Mono", Menlo, monospace; letter-spacing: .08em;
            text-transform: uppercase; color: var(--faint); }
    [hidden] { display: none !important; }
    </style></head>
    <body><main>
      <!-- Nidus's product icon: tile-amber, Solanum's broken ring, five ribbons. -->
      <svg class="icon" viewBox="0 0 200 200" aria-hidden="true">
        <rect width="200" height="200" rx="44" fill="#d9a441"/>
        <g transform="translate(35.5 35.5) scale(.645)" fill="none" stroke="#141413" stroke-linecap="round" stroke-linejoin="round">
          <path stroke-width="7" d="M160.81 39.19A86 86 0 1 1 122.26 16.93"/>
          <g stroke-width="9"><path d="M100 74 L102.4 69.7 L105.5 65.8 L109.3 62.6 L113.6 60.2 L118.3 58.7 L123.1 57.9 L128.1 57.7 L133 58.1 L137.9 58.9 L142.7 59.9 L147.5 61.3 L152.2 62.8 L156.8 64.5"/><path d="M124.7 92 L129.6 92.9 L134.2 94.7 L138.4 97.3 L142 100.6 L144.9 104.6 L147.2 109 L148.9 113.6 L150 118.4 L150.8 123.3 L151.3 128.2 L151.5 133.2 L151.5 138.1 L151.3 143.1"/><path d="M115.3 121 L115.9 125.9 L115.6 130.9 L114.5 135.7 L112.4 140.1 L109.5 144.2 L106 147.7 L102.1 150.7 L97.9 153.3 L93.5 155.6 L89 157.5 L84.4 159.3 L79.7 160.8 L74.9 162.1"/><path d="M84.7 121 L80.2 123.1 L75.5 124.4 L70.5 124.8 L65.6 124.2 L60.9 122.7 L56.5 120.5 L52.4 117.7 L48.7 114.5 L45.2 111 L41.9 107.3 L38.8 103.4 L35.9 99.4 L33.2 95.3"/><path d="M75.3 92 L71.9 88.3 L69.2 84.2 L67.3 79.6 L66.4 74.8 L66.4 69.9 L67.1 65 L68.5 60.2 L70.4 55.7 L72.6 51.2 L75.1 47 L77.8 42.9 L80.7 38.9 L83.8 35"/></g>
        </g>
      </svg>
      <p class="overline">Focus session</p>
      <h1>Stay with it.</h1>
      <p class="lede" id="site">This page is blocked until your session ends.</p>
      <div class="goal" id="goal" hidden><p class="overline">Your goal</p><div id="goal-text"></div></div>
      <div class="actions"><a class="snooze" id="snooze" hidden>Snooze</a></div>
      <p class="fine">Nidus · A Solanum product · Nothing leaves this Mac</p>
    </main>
    <script>
    const q = new URLSearchParams(location.search);
    let host = "";
    try { host = new URL(q.get("u")).hostname.replace(/^www\\./, ""); } catch {}
    if (host) {
      document.getElementById("site").textContent = host + " is blocked until your session ends.";
      document.title = host + " is blocked";
      // m=0: a strict session, which has no snooze. Missing: 3.
      const m = parseInt(q.get("m"), 10);
      const minutes = Number.isNaN(m) ? 3 : m;
      if (minutes > 0) {
        const snooze = document.getElementById("snooze");
        snooze.textContent = "Snooze for " + minutes + (minutes === 1 ? " minute" : " minutes");
        snooze.href = "nidus://snooze?site=" + encodeURIComponent(q.get("s") || host);
        snooze.hidden = false;
      }
    }
    const goal = (q.get("g") || "").trim();
    if (goal) { document.getElementById("goal-text").textContent = goal; document.getElementById("goal").hidden = false; }
    </script>
    </body></html>
    """
}

/// Matches a URL against blocked domains: `youtube.com` blocks
/// `www.youtube.com` and `m.youtube.com`, not `notyoutube.com`.
struct DomainMatcher: Sendable {
    let domains: Set<String>

    init(_ domains: [String]) {
        self.domains = Set(domains.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) })
    }

    static func isWebPage(_ url: String) -> Bool {
        guard let scheme = URLComponents(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    func matches(_ url: String) -> Bool {
        matchedDomain(url) != nil
    }

    /// The listed domain that covers this URL, if any.
    func matchedDomain(_ url: String) -> String? {
        guard Self.isWebPage(url), var host = URLComponents(string: url)?.host?.lowercased() else { return nil }
        while true {
            if domains.contains(host) { return host }
            guard let dot = host.firstIndex(of: ".") else { return nil }
            host = String(host[host.index(after: dot)...])
        }
    }

    /// The host as a person would write it: lowercased, without `www.`.
    static func displayHost(_ url: String) -> String? {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Which pages a session blocks: the listed domains, or everything but them.
struct WebsiteRule: Sendable {
    enum Mode: Sendable { case block, allow }

    let mode: Mode
    let matcher: DomainMatcher

    init(mode: Mode, domains: [String]) {
        self.mode = mode
        matcher = DomainMatcher(domains)
    }

    /// Only web pages are ever blocked; `about:`, `file:` and the browser's
    /// own pages are left alone in either mode.
    func blocks(_ url: String) -> Bool {
        switch mode {
        case .block: return matcher.matches(url)
        case .allow: return DomainMatcher.isWebPage(url) && !matcher.matches(url)
        }
    }

    /// What snoozing this blocked URL lets through: the list entry that
    /// caught it, or in allow mode the site itself.
    func snoozeKey(for url: String) -> String {
        switch mode {
        case .block: return matcher.matchedDomain(url) ?? DomainMatcher.displayHost(url) ?? url
        case .allow: return DomainMatcher.displayHost(url) ?? url
        }
    }
}

/// Stateless and blocking: every call sends Apple Events and waits up to the
/// timeout. Call it off the main thread.
struct BrowserBlocker: Sendable {
    let blockPage: BlockPage
    var timeout: TimeInterval = 2

    /// Every tab of a running browser. An empty array when it is not running,
    /// in which case nothing was sent.
    func tabs(in browser: BrowserProfile) throws(AppleEventError) -> [TabLocation] {
        guard let target = AppleEventTarget(runningBundleID: browser.bundleID) else { return [] }
        let windows = ObjectSpecifier.every("cwin")
        // Two bulk reads, not one per tab. The windows are listed in the same
        // order both times; a window opening between the two shows up as a
        // count mismatch, and the caller retries on the next sweep.
        let ids = try target.get(ObjectSpecifier.property("ID  ", of: windows), timeout: timeout).listItems
        let urls = try target.get(ObjectSpecifier.property(browser.urlProperty,
                                                           of: ObjectSpecifier.every(browser.tabClass, of: windows)),
                                  timeout: timeout).listItems
        guard ids.count == urls.count else { throw .failed(-1) }
        var result: [TabLocation] = []
        for (window, tabURLs) in zip(ids, urls) {
            for (offset, url) in tabURLs.listItems.enumerated() {
                guard let string = url.stringValue else { continue }
                result.append(TabLocation(windowID: Int(window.int32Value), index: offset + 1, url: string))
            }
        }
        return result
    }

    /// Points each tab the rule blocks at the block page. Returns the snooze
    /// key of each tab it redirected.
    @discardableResult
    func sweep(_ browser: BrowserProfile, rule: WebsiteRule, goal: String = "", snoozeMinutes: Int = 3) throws(AppleEventError) -> [String] {
        var redirected: [String] = []
        for tab in try tabs(in: browser) where rule.blocks(tab.url) {
            let key = rule.snoozeKey(for: tab.url)
            let page = blockPage.url(blocking: tab.url, goal: goal, snoozeMinutes: snoozeMinutes, snoozeKey: key)
            if try replace(tab, in: browser, with: page) {
                redirected.append(key)
            }
        }
        return redirected
    }

    /// Puts block-page tabs back on the URL they were showing: every one, or
    /// with `keepBlocked`, those the rule no longer blocks (after a snooze).
    @discardableResult
    func restore(_ browser: BrowserProfile, keepBlocked rule: WebsiteRule? = nil) throws(AppleEventError) -> [String] {
        var restored: [String] = []
        for tab in try tabs(in: browser) {
            guard let original = blockPage.original(from: tab.url) else { continue }
            if let rule, rule.blocks(original) { continue }
            if try replace(tab, in: browser, with: original) {
                restored.append(original)
            }
        }
        return restored
    }

    /// Sets one tab's URL, after checking it still shows what the snapshot
    /// saw: tabs are addressed by index, and indices shift when tabs close.
    func replace(_ tab: TabLocation, in browser: BrowserProfile, with url: String) throws(AppleEventError) -> Bool {
        guard let target = AppleEventTarget(runningBundleID: browser.bundleID) else { return false }
        let tabSpec = ObjectSpecifier.index(browser.tabClass, tab.index, of: ObjectSpecifier.id("cwin", tab.windowID))
        let urlSpec = ObjectSpecifier.property(browser.urlProperty, of: tabSpec)
        guard try target.get(urlSpec, timeout: timeout).stringValue == tab.url else { return false }
        try target.set(urlSpec, to: NSAppleEventDescriptor(string: url), timeout: timeout)
        return true
    }
}
