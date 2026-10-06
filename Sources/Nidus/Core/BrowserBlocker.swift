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
/// codes: Chrome's tab class is `CrTb`, Opera's is `OpTb`. A wrong code does
/// not fail loudly, it leaves the browser's sites unblocked, so add a browser
/// only with its codes read from a primary source for that browser: its own
/// .sdef (Safari, Chrome and Opera Air were read from the installed apps), or
/// its published source showing which scripting.sdef it ships. That a browser
/// is built on Chromium proves nothing.
///
/// Every browser is addressed alike: `every window` (`cwin`) and each one's
/// `ID  `, then `every <tab class>` and its URL property. Only the tab class
/// and the URL property vary.
///
/// Not added, for want of a primary source: Edge, Arc, Dia, Orion, Vivaldi.
/// Read their codes from the installed app first (see the tests).
struct BrowserProfile: Sendable, Hashable {
    let name: String
    let bundleID: String
    let tabClass: String
    let urlProperty: String

    static let safari = BrowserProfile(name: "Safari", bundleID: "com.apple.Safari", tabClass: "bTab", urlProperty: "pURL")
    static let chrome = BrowserProfile(name: "Google Chrome", bundleID: "com.google.Chrome", tabClass: "CrTb", urlProperty: "URL ")
    static let operaAir = BrowserProfile(name: "Opera Air", bundleID: "com.operasoftware.OperaAir", tabClass: "OpTb", urlProperty: "URL ")
    /// Chromium's own scripting.sdef (chrome/browser/ui/cocoa/applescript in
    /// the chromium repository) is bundled by the Chromium build, so an
    /// unbranded Chromium has Chrome's codes.
    static let chromium = BrowserProfile(name: "Chromium", bundleID: "org.chromium.Chromium", tabClass: "CrTb", urlProperty: "URL ")
    /// brave-core builds Chromium's app plist, which names scripting.sdef, and
    /// replaces neither: Brave ships Chromium's dictionary unchanged.
    static let brave = BrowserProfile(name: "Brave Browser", bundleID: "com.brave.Browser", tabClass: "CrTb", urlProperty: "URL ")

    /// Settings lists only those that are installed, and a sweep sends
    /// nothing to one that is not running, so a long list costs nothing.
    static let known: [BrowserProfile] = [.safari, .chrome, .operaAir, .brave, .chromium]
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
      // What is blocked: the list entry that caught this page, path and all
      // ("youtube.com/shorts"), or the site itself when there is none.
      const key = (q.get("s") || "").trim();
      const what = key || host;
      document.getElementById("site").textContent = what + " is blocked until your session ends.";
      document.title = what + " is blocked";
      // m=0: a strict session, which has no snooze. Missing: 3.
      const m = parseInt(q.get("m"), 10);
      const minutes = Number.isNaN(m) ? 3 : m;
      if (minutes > 0) {
        const snooze = document.getElementById("snooze");
        snooze.textContent = "Snooze for " + minutes + (minutes === 1 ? " minute" : " minutes");
        snooze.href = "nidus://snooze?site=" + encodeURIComponent(key || host);
        snooze.hidden = false;
      }
    }
    const goal = (q.get("g") || "").trim();
    if (goal) { document.getElementById("goal-text").textContent = goal; document.getElementById("goal").hidden = false; }
    </script>
    </body></html>
    """
}

/// One website rule: a host, and optionally a path under it. `youtube.com`
/// covers the whole site; `youtube.com/shorts` covers `/shorts` and what is
/// below it, and nothing else on the site.
///
/// Rules stay the plain strings people type (`FocusCategory.websites`, a
/// session's plan), so saved data needs no migration and a rule without a
/// path is the domain it always was. This type is how such a string is read.
///
/// - The host matches the page's host or any parent of it: `youtube.com`
///   covers `m.youtube.com`, not `notyoutube.com`. Hosts compare without
///   regard to case.
/// - The path matches whole segments from the start: `/shorts` covers
///   `/shorts` and `/shorts/abc`, not `/shortsfoo` or `/a/shorts`. Paths also
///   compare without regard to case, which is friendlier (nobody means
///   `/Shorts` as a different page) and errs toward blocking. A trailing or
///   doubled slash makes no difference, and percent-encoding is undone first,
///   so `/%73horts` does not slip past `/shorts`.
/// - A query or fragment is never part of a rule: a page is its host and path.
struct WebsiteEntry: Sendable, Hashable {
    /// Lowercase, without `www.`, a port or a trailing dot.
    let host: String
    /// The path's segments, lowercase and decoded. Empty: the whole site.
    let segments: [String]

    /// The rule as saved, shown, snoozed and counted: "youtube.com/shorts".
    var text: String { host + segments.map { "/" + $0 }.joined() }

    /// A rule from what someone typed or pasted into "Add a website": a bare
    /// domain, an address copied from the browser, or anything between. nil
    /// for what is not a web address (an email, `chrome://settings`, a name
    /// with no dot), so garbage is refused instead of saved as a rule that
    /// never matches.
    init?(typed input: String) {
        self.init(parsing: input, tolerant: false)
    }

    /// A rule read back from saved data. Takes what `init(typed:)` takes, and
    /// also forgives stray dots and spaces around the domain (`news.ycombinator.com.`),
    /// which earlier versions matched, and leaves `www.` alone since it was
    /// never stripped from what is already saved.
    init?(stored text: String) {
        self.init(parsing: text, tolerant: true)
    }

    private init?(parsing input: String, tolerant: Bool) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if tolerant { text = text.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
        // Web addresses only: a scheme of any other kind is not one.
        if let scheme = text.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*://"#, options: .regularExpression) {
            guard ["http://", "https://"].contains(text[scheme].lowercased()) else { return nil }
            text.removeSubrange(scheme)
        } else if text.hasPrefix("//") {
            text.removeFirst(2)
        }
        if let end = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<end]) }
        let slash = text.firstIndex(of: "/")
        var authority = String(slash.map { text[..<$0] } ?? text[...])
        let path = slash.map { String(text[$0...]) } ?? ""

        // `name@host` is an email address or a login, never a site to block.
        guard !authority.contains("@") else { return nil }
        if let colon = authority.lastIndex(of: ":") {
            let port = authority[authority.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            authority = String(authority[..<colon])
        }
        var host = authority.lowercased()
        if tolerant {
            host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        } else if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        // Through URLComponents so a typed `bücher.de` and the `xn--` form a
        // browser reports end up as the same host, as they do for a page.
        guard Self.isValid(host: host),
              let canonical = URLComponents(string: "https://" + host)?.host?.lowercased() else { return nil }
        self.host = canonical
        segments = Self.segments(ofPath: path)
    }

    /// Whether this rule covers a page.
    func covers(_ location: WebLocation) -> Bool {
        (location.host == host || location.host.hasSuffix("." + host)) && location.segments.starts(with: segments)
    }

    /// Of two rules covering the same page, whether this one says more: more
    /// path first (`youtube.com/shorts` over `youtube.com`), then more host
    /// (`m.youtube.com` over `youtube.com`).
    func isNarrower(than other: WebsiteEntry) -> Bool {
        (segments.count, hostLabels) > (other.segments.count, other.hostLabels)
    }

    private var hostLabels: Int { host.reduce(1) { $1 == "." ? $0 + 1 : $0 } }

    /// At least two labels of letters, digits, `-` and `_`. A dotless name
    /// would otherwise be a rule for a whole top-level domain.
    private static func isValid(host: String) -> Bool {
        guard host.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            (1...63).contains(label.count) && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    /// The segments of a path as typed or as a browser reports it, in the one
    /// form both are compared in. Empty and `.` segments vanish and `..`
    /// steps back, as a browser would have resolved them.
    static func segments(ofPath path: String) -> [String] {
        var result: [String] = []
        for part in path.split(separator: "/") {
            switch canonical(part) {
            case ".": continue
            case "..": _ = result.popLast()
            case let segment: result.append(segment)
            }
        }
        return result
    }

    /// Decoded and lowercased, then encoded again only where the text would
    /// otherwise break: `/`, `?`, `#`, `%` and whitespace. That makes a rule's
    /// text read back as the same rule, which the Snooze link relies on, and
    /// leaves accented letters readable (`addingPercentEncoding` would not).
    private static func canonical(_ segment: Substring) -> String {
        let decoded = (String(segment).removingPercentEncoding ?? String(segment)).lowercased()
        var result = ""
        for scalar in decoded.unicodeScalars {
            if mustEscape.contains(scalar) {
                for byte in String(scalar).utf8 { result += String(format: "%%%02X", byte) }
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static let mustEscape: CharacterSet = {
        var reserved = CharacterSet(charactersIn: "%/?#")
        reserved.formUnion(.whitespacesAndNewlines)
        reserved.formUnion(.controlCharacters)
        return reserved
    }()
}

/// Where a tab is, for matching: the host and path of a web page.
struct WebLocation: Sendable, Hashable {
    let host: String
    let segments: [String]

    /// nil for anything that is not an http or https page.
    init?(_ url: String) {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased() else { return nil }
        // `youtube.com.` is the same site as `youtube.com`.
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmed.isEmpty else { return nil }
        self.host = trimmed
        segments = WebsiteEntry.segments(ofPath: components.percentEncodedPath)
    }
}

/// Matches a URL against the listed websites: `youtube.com` blocks
/// `www.youtube.com` and `m.youtube.com`, not `notyoutube.com`, and
/// `youtube.com/shorts` blocks only that part of it (see `WebsiteEntry`).
///
/// An entry that is not a web address (empty, `/shorts`, a stray word) is left
/// out. It can never act as a wildcard.
struct DomainMatcher: Sendable {
    /// The entries as `WebsiteEntry.text` writes them.
    let domains: Set<String>
    private let entries: [WebsiteEntry]

    init(_ domains: [String]) {
        entries = domains.compactMap { WebsiteEntry(stored: $0) }
        self.domains = Set(entries.map(\.text))
    }

    static func isWebPage(_ url: String) -> Bool {
        guard let scheme = URLComponents(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    func matches(_ url: String) -> Bool {
        matchedDomain(url) != nil
    }

    /// The listed entry that covers this URL, as written ("youtube.com" or
    /// "youtube.com/shorts"). When several do, the one that says the most.
    func matchedDomain(_ url: String) -> String? {
        guard let location = WebLocation(url) else { return nil }
        var best: WebsiteEntry?
        for entry in entries where entry.covers(location) {
            if let current = best, !entry.isNarrower(than: current) { continue }
            best = entry
        }
        return best?.text
    }

    /// The host as a person would write it: lowercased, without `www.`.
    static func displayHost(_ url: String) -> String? {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Which pages a session blocks: the listed websites, or everything but them.
struct WebsiteRule: Sendable {
    enum Mode: Sendable { case block, allow }

    let mode: Mode
    let matcher: DomainMatcher
    /// Entries snoozed right now. Where listed entries overlap (`youtube.com`
    /// and `youtube.com/shorts`), taking one off the list would leave the
    /// other still blocking the page, so a snooze lets through everything the
    /// snoozed entry covers, whatever else covers it too. Only block mode
    /// needs it: allow mode adds the snoozed site to the list instead.
    private let snoozed: DomainMatcher

    init(mode: Mode, domains: [String], snoozed: [String] = []) {
        self.mode = mode
        matcher = DomainMatcher(domains)
        self.snoozed = DomainMatcher(snoozed)
    }

    /// Only web pages are ever blocked; `about:`, `file:` and the browser's
    /// own pages are left alone in either mode.
    ///
    /// In allow mode a page is allowed when any entry covers it. An entry
    /// with a path allows that part and what is below it; the pages above it
    /// stay blocked, so `github.com/samporter14` lets `/samporter14/nidus`
    /// through but not `github.com` itself or `/other`.
    func blocks(_ url: String) -> Bool {
        switch mode {
        case .block: return matcher.matches(url) && !snoozed.matches(url)
        case .allow: return DomainMatcher.isWebPage(url) && !matcher.matches(url)
        }
    }

    /// What snoozing this blocked URL lets through. In block mode the list
    /// entry that caught it, path and all, so snoozing `youtube.com/shorts`
    /// lets shorts through and nothing else, and `m.youtube.com` snoozes
    /// `youtube.com`. In allow mode the site itself (host only, since the
    /// listed paths are what was allowed and this page is none of them).
    func snoozeKey(for url: String) -> String {
        switch mode {
        case .block: return matcher.matchedDomain(url) ?? DomainMatcher.displayHost(url) ?? url
        case .allow: return DomainMatcher.displayHost(url) ?? url
        }
    }
}

/// A tab the rule blocks: where it is, the block page that replaces it, and
/// the snooze key of the entry that caught it.
struct TabRedirect: Sendable, Hashable {
    let tab: TabLocation
    let page: String
    let key: String
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

    /// The tabs the rule blocks and where each goes. No Apple Events, so the
    /// choice of tabs is testable.
    func redirects(for tabs: [TabLocation], rule: WebsiteRule, goal: String = "", snoozeMinutes: Int = 3) -> [TabRedirect] {
        tabs.filter { rule.blocks($0.url) }.map { tab in
            let key = rule.snoozeKey(for: tab.url)
            return TabRedirect(tab: tab,
                               page: blockPage.url(blocking: tab.url, goal: goal, snoozeMinutes: snoozeMinutes, snoozeKey: key),
                               key: key)
        }
    }

    /// The block-page tabs to put back, and the page each was showing: every
    /// one, or with `keepBlocked`, those the rule no longer blocks (after a
    /// snooze). The block page carries the whole original address, path
    /// included, so a tab blocked for `youtube.com/shorts` returns to the
    /// very short it was on.
    func restorations(in tabs: [TabLocation], keepBlocked rule: WebsiteRule? = nil) -> [(tab: TabLocation, original: String)] {
        tabs.compactMap { tab in
            guard let original = blockPage.original(from: tab.url) else { return nil }
            if let rule, rule.blocks(original) { return nil }
            return (tab, original)
        }
    }

    /// Points each tab the rule blocks at the block page. Returns the snooze
    /// key of each tab it redirected.
    @discardableResult
    func sweep(_ browser: BrowserProfile, rule: WebsiteRule, goal: String = "", snoozeMinutes: Int = 3) throws(AppleEventError) -> [String] {
        var redirected: [String] = []
        for redirect in redirects(for: try tabs(in: browser), rule: rule, goal: goal, snoozeMinutes: snoozeMinutes) {
            if try replace(redirect.tab, in: browser, with: redirect.page) {
                redirected.append(redirect.key)
            }
        }
        return redirected
    }

    /// Puts block-page tabs back on the URL they were showing: every one, or
    /// with `keepBlocked`, those the rule no longer blocks (after a snooze).
    @discardableResult
    func restore(_ browser: BrowserProfile, keepBlocked rule: WebsiteRule? = nil) throws(AppleEventError) -> [String] {
        var restored: [String] = []
        for (tab, original) in restorations(in: try tabs(in: browser), keepBlocked: rule) {
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
