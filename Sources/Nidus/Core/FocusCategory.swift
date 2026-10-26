//
//  FocusCategory.swift
//  Nidus
//
//  A named group of apps and websites, the unit a session is built from:
//  "block Social and Messaging for 45 minutes". Presets cover the usual
//  distractions so the first session needs no setup.
//

import Foundation

struct BlockedApp: Codable, Hashable, Sendable, Identifiable {
    var bundleID: String
    /// Shown in lists and HUDs; captured when the app is added.
    var name: String

    var id: String { bundleID }
}

struct FocusCategory: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    /// An SF Symbol.
    var symbol: String
    var apps: [BlockedApp]
    var websites: [String]
    /// Pages let through although one of `websites` covers them. 0.4.
    var websiteExceptions: [WebsiteException] = []

    var isEmpty: Bool { apps.isEmpty && websites.isEmpty }

    /// "3 apps, 5 websites", for a row's subtitle. Exceptions are counted
    /// only when there are some.
    var summary: String {
        let parts = [Self.count(apps.count, "app"), Self.count(websites.count, "website"),
                     Self.count(websiteExceptions.count, "exception")].compactMap { $0 }
        return parts.isEmpty ? "Empty" : parts.joined(separator: ", ")
    }

    private static func count(_ n: Int, _ noun: String) -> String? {
        n == 0 ? nil : "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

extension FocusCategory {
    enum CodingKeys: String, CodingKey { case id, name, symbol, apps, websites, websiteExceptions }

    /// 0.3's fields as before; the exceptions on their own, so a category
    /// saved before 0.4 (or one exception written wrongly) still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.decode(String.self, forKey: .symbol)
        apps = try c.decode([BlockedApp].self, forKey: .apps)
        websites = try c.decode([String].self, forKey: .websites)
        websiteExceptions = c.decodeLossy([WebsiteException].self, forKey: .websiteExceptions)
    }
}

extension FocusCategory {
    static let presets: [FocusCategory] = PresetUpdates.applying(to: [
        FocusCategory(
            id: "social", name: "Social", symbol: "person.2",
            apps: [],
            websites: ["x.com", "twitter.com", "facebook.com", "instagram.com", "threads.net",
                       "bsky.app", "reddit.com", "tiktok.com", "linkedin.com"]
        ),
        FocusCategory(
            id: "messaging", name: "Messaging", symbol: "bubble.left.and.bubble.right",
            apps: [BlockedApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
                   BlockedApp(bundleID: "com.apple.MobileSMS", name: "Messages"),
                   BlockedApp(bundleID: "com.hnc.Discord", name: "Discord"),
                   BlockedApp(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp"),
                   BlockedApp(bundleID: "ru.keepcoder.Telegram", name: "Telegram")],
            websites: ["messenger.com", "web.whatsapp.com", "discord.com"]
        ),
        FocusCategory(
            id: "video", name: "Video", symbol: "play.rectangle",
            apps: [BlockedApp(bundleID: "com.apple.TV", name: "TV")],
            websites: ["youtube.com", "netflix.com", "twitch.tv", "primevideo.com",
                       "disneyplus.com", "max.com", "hulu.com"]
        ),
        FocusCategory(
            id: "news", name: "News", symbol: "newspaper",
            apps: [BlockedApp(bundleID: "com.apple.news", name: "News")],
            websites: ["news.ycombinator.com", "cnn.com", "bbc.com", "bbc.co.uk", "nytimes.com",
                       "theguardian.com", "theverge.com"] + PresetUpdates.newsSites
        ),
        FocusCategory(
            id: "mail", name: "Mail", symbol: "envelope",
            apps: [BlockedApp(bundleID: "com.apple.mail", name: "Mail"),
                   BlockedApp(bundleID: "com.microsoft.Outlook", name: "Outlook")],
            websites: ["mail.google.com", "outlook.live.com", "outlook.office.com"]
        ),
    ] + PresetUpdates.suggestedCategories, since: 1)

    /// What a session blocks when the user has picked no category yet.
    static let defaultSelection: [String] = ["social", "video"]

    /// Normalises what the user typed into a website rule: a bare domain, or
    /// a domain with a path to block only that part of it.
    /// "https://www.YouTube.com/shorts/?feature=share#top" becomes
    /// "youtube.com/shorts". The scheme, `www.`, port, query, fragment and
    /// trailing slash go; the path stays, lowercased. nil for what is not a
    /// web address. Reading a rule back through this gives the same rule,
    /// which `nidus://snooze` depends on.
    ///
    /// Named for when a rule was only a domain; callers still use it.
    static func domain(from input: String) -> String? {
        WebsiteEntry(typed: input)?.text
    }
}

extension SessionPlan {
    /// A plan from the chosen categories. Duplicates across categories are
    /// merged; order does not matter to the blockers.
    init(goal: String, duration: TimeInterval?, mode: Mode, categories: [FocusCategory], reopensQuitApps: Bool,
         launchApps: [String] = [], startShortcut: String? = nil, endShortcut: String? = nil) {
        var apps: [String] = []
        var websites: [String] = []
        for category in categories {
            for app in category.apps where !apps.contains(app.bundleID) { apps.append(app.bundleID) }
            for site in category.websites where !websites.contains(site) { websites.append(site) }
        }
        self.init(goal: goal, duration: duration, mode: mode, apps: apps, websites: websites,
                  reopensQuitApps: reopensQuitApps, launchApps: launchApps,
                  startShortcut: startShortcut, endShortcut: endShortcut)
    }
}


// MARK: - Better defaults reach existing installs

/// Sites added to the preset categories after a person's own copy was saved.
/// Each version's sites are added once, to a category still named by its
/// preset id: nothing is ever removed, a site the person took out later stays
/// out (the version is recorded), and categories they made themselves are
/// never touched.
enum PresetUpdates {
    /// The sites News has had since version 1: wire services, broadcasters,
    /// papers, magazines and the main tech and business news sites.
    static let newsSites = [
        "reuters.com", "apnews.com", "bloomberg.com", "npr.org", "washingtonpost.com", "wsj.com",
        "latimes.com", "usatoday.com", "foxnews.com", "nbcnews.com", "cbsnews.com", "abcnews.go.com",
        "msnbc.com", "news.google.com", "news.yahoo.com", "politico.com", "axios.com", "thehill.com",
        "huffpost.com", "vox.com", "slate.com", "time.com", "newsweek.com", "nypost.com",
        "theatlantic.com", "newyorker.com", "economist.com", "ft.com", "forbes.com", "businessinsider.com",
        "cnbc.com", "aljazeera.com", "independent.co.uk", "telegraph.co.uk", "dailymail.co.uk", "sky.com",
        "dw.com", "france24.com", "techcrunch.com", "wired.com", "arstechnica.com", "engadget.com",
    ]

    static let socialSites = ["tumblr.com", "pinterest.com", "snapchat.com", "mastodon.social", "t.co",
                              "lnkd.in", "substack.com/notes", "bereal.com", "truthsocial.com"]
    static let videoSites = ["youtu.be", "vimeo.com", "crunchyroll.com", "peacocktv.com", "paramountplus.com",
                             "tv.apple.com", "dailymotion.com", "kick.com", "rumble.com", "hotstar.com"]
    static let messagingSites = ["web.telegram.org", "app.slack.com", "teams.microsoft.com", "signal.me",
                                 "wechat.com", "line.me", "viber.com"]
    static let mailSites = ["mail.yahoo.com", "proton.me", "icloud.com/mail", "fastmail.com", "app.hey.com",
                            "superhuman.com"]
    static let messagingApps = [BlockedApp(bundleID: "org.whispersystems.signal-desktop", name: "Signal"),
                                BlockedApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams")]
    static let mailApps = [BlockedApp(bundleID: "com.readdle.SparkDesktop", name: "Spark"),
                           BlockedApp(bundleID: "com.superhuman.mail", name: "Superhuman"),
                           BlockedApp(bundleID: "it.bloop.airmail2", name: "Airmail"),
                           BlockedApp(bundleID: "org.mozilla.thunderbird", name: "Thunderbird")]

    /// Whole new categories are offered explicitly, never inserted into a
    /// saved list. Removing one keeps it removed until Add is pressed again.
    static let suggestedCategories: [FocusCategory] = [
        .init(id: "shopping", name: "Shopping", symbol: "cart", apps: [], websites:
            ["amazon.com", "amazon.co.uk", "amazon.ca", "amazon.de", "amazon.fr", "amazon.co.jp", "amzn.to",
             "ebay.com", "ebay.co.uk", "etsy.com", "aliexpress.com", "temu.com", "shein.com", "walmart.com", "target.com"]),
        .init(id: "games", name: "Games", symbol: "gamecontroller", apps: [], websites:
            ["steampowered.com", "steamcommunity.com", "epicgames.com", "roblox.com", "ign.com", "gamespot.com"]),
        .init(id: "sports", name: "Sports", symbol: "sportscourt", apps: [], websites:
            ["espn.com", "bleacherreport.com", "theathletic.com", "nfl.com", "nba.com", "nhl.com", "mlb.com"]),
        .init(id: "finance", name: "Finance", symbol: "chart.line.uptrend.xyaxis", apps: [], websites:
            ["robinhood.com", "finance.yahoo.com", "coinbase.com", "tradingview.com"]),
        .init(id: "forums", name: "Forums and Q&A", symbol: "text.bubble", apps: [], websites:
            ["reddit.com", "quora.com", "news.ycombinator.com"]),
        .init(id: "ai-chat", name: "AI chat", symbol: "sparkles", apps: [], websites:
            ["chatgpt.com", "claude.ai", "gemini.google.com", "perplexity.ai"]),
    ]

    static let currentVersion = 2

    /// Sites to add per preset id, by the version that introduced them.
    static let additions: [(version: Int, id: String, sites: [String])] = [
        (1, "news", newsSites),
        (2, "social", socialSites),
        (2, "video", videoSites),
        (2, "messaging", messagingSites),
        (2, "mail", mailSites),
    ]

    /// `categories` with every addition newer than `savedVersion` appended
    /// where it is missing.
    static func applying(to categories: [FocusCategory], since savedVersion: Int) -> [FocusCategory] {
        var result = categories
        for addition in additions where addition.version > savedVersion {
            guard let index = result.firstIndex(where: { $0.id == addition.id }) else { continue }
            let have = Set(result[index].websites.map { $0.lowercased() })
            result[index].websites += addition.sites.filter { !have.contains($0) }
        }
        if savedVersion < 2 {
            for (id, apps) in [("messaging", messagingApps), ("mail", mailApps)] {
                guard let index = result.firstIndex(where: { $0.id == id }) else { continue }
                let have = Set(result[index].apps.map(\.bundleID))
                result[index].apps += apps.filter { !have.contains($0.bundleID) }
            }
        }
        return result
    }
}


extension FocusCategory {
    /// Counts plus a small preview, without retaining icons or page metadata.
    var coverageSummary: String {
        let preview = websites.prefix(3).joined(separator: ", ")
        return preview.isEmpty ? summary : summary + " · " + preview + (websites.count > 3 ? ", …" : "")
    }

    static func suggested(in categories: [FocusCategory]) -> [FocusCategory] {
        let existing = Set(categories.map(\.id))
        return presets.filter { !existing.contains($0.id) }
    }

    /// A merge is only offered when every rule is already in the built-in
    /// category. Exceptions and app rules must also be preserved verbatim.
    func mergeTarget(in categories: [FocusCategory]) -> FocusCategory? {
        let presetIDs = Set(Self.presets.map(\.id))
        guard !presetIDs.contains(id), !isEmpty else { return nil }
        let sites = Set(websites.compactMap(Self.domain(from:)))
        guard sites.count == websites.count else { return nil }
        return categories.first { candidate in
            candidate.id != id && presetIDs.contains(candidate.id)
                && sites.isSubset(of: Set(candidate.websites.compactMap(Self.domain(from:))))
                && Set(apps.map(\.bundleID)).isSubset(of: Set(candidate.apps.map(\.bundleID)))
                && Set(websiteExceptions).isSubset(of: Set(candidate.websiteExceptions))
        }
    }
}
