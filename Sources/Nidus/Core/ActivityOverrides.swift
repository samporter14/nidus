//
//  ActivityOverrides.swift
//  Nidus
//
//  "Count as" for Activity. By default an app or website counts under the
//  focus category whose blocking list holds it. An override says otherwise
//  for the Activity views only: it lives in its own preference and never
//  touches a category's apps, websites or exceptions, so moving a site in
//  Activity cannot change what a session blocks.
//
//  Pure, so it is tested without a model. `ActivityCategorizer` reads it.
//

import Foundation

/// Where an app or website counts.
enum ActivityGroup: Equatable, Sendable, Codable {
    case work
    case category(String)
    case uncategorized

    init(id: String?) {
        switch id {
        case nil: self = .uncategorized
        case ActivityCategorizer.workID?: self = .work
        case let id?: self = .category(id)
        }
    }

    // One string, so a category id can never be mistaken for Work.
    private static let categoryPrefix = "category:"

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        switch text {
        case "work": self = .work
        case "uncategorized": self = .uncategorized
        case _ where text.hasPrefix(Self.categoryPrefix) && text.count > Self.categoryPrefix.count:
            self = .category(String(text.dropFirst(Self.categoryPrefix.count)))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown group"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .work: try container.encode("work")
        case .uncategorized: try container.encode("uncategorized")
        case .category(let id): try container.encode(Self.categoryPrefix + id)
        }
    }
}

struct ActivityOverrides: Codable, Equatable, Sendable {
    /// One override, with the name the editor shows: the app may be gone and
    /// the day files keep only a bundle id.
    struct Entry: Codable, Equatable, Sendable {
        var group: ActivityGroup
        var name: String
    }

    /// Browser time with no readable website behind it, counted as a bucket of
    /// its own so sorting it never has to categorize the whole browser app.
    enum BrowserPage: String, CaseIterable, Sendable {
        /// localhost and dev servers, intranet and single-label hosts, chrome://,
        /// file://, about:, new tabs and pages that could not be read.
        case local
        /// The local Claude Science tab: a label with no address.
        case science

        var title: String {
            switch self {
            case .local: return "Local and browser pages"
            case .science: return "Claude Science"
            }
        }
    }

    /// What an override is about: an app by bundle id, a website by its bare
    /// host, a whole registrable domain, or a bucket of browser pages with no
    /// website. A `.site` override covers that exact host only, not its
    /// subdomains: a rule on `google.com` should not pull `docs.google.com`
    /// along when it is counted on its own. A `.domain` override is the
    /// opt-in for "everything under google.com"; an exact `.site` override
    /// still wins over it.
    enum Subject: Hashable, Sendable {
        case app(String)
        case site(String)
        case domain(String)
        case page(BrowserPage)
    }

    var apps: [String: Entry] = [:]
    var sites: [String: Entry] = [:]
    /// Registrable domain -> override that also covers its subdomains.
    var domains: [String: Entry] = [:]
    /// `BrowserPage.rawValue` -> override for that bucket.
    var pages: [String: Entry] = [:]

    var isEmpty: Bool { apps.isEmpty && sites.isEmpty && domains.isEmpty && pages.isEmpty }

    /// Whether anything is counted as Work.
    var countsAnythingAsWork: Bool {
        [apps, sites, domains, pages].contains { $0.values.contains { $0.group == .work } }
    }

    /// The bucket a stretch falls in when it is a browser with no website
    /// host to name; nil for an app or a stretch with a host.
    static func browserPage(appID: String?, site: String?, url: String?) -> BrowserPage? {
        guard let appID, FocusController.isBrowser(appID), host(site: site, url: url) == nil else { return nil }
        return site == "Claude Science" ? .science : .local
    }

    // MARK: Items

    /// The bare host of a stretch's page (no `www.`), as a website override
    /// is keyed. nil for an app, a local tab or an address with no host.
    static func host(site: String?, url: String?) -> String? {
        ActivityCategorizer.address(site: site, url: url).flatMap { ActivityDomain.site(from: $0) }
    }

    /// A website when there is a host to name, else the app.
    static func subject(appID: String?, site: String?, url: String?) -> Subject? {
        if let host = host(site: site, url: url) { return .site(host) }
        return appID.map { .app($0) }
    }

    /// Every override, A to Z by name, for the editor.
    var items: [(subject: Subject, entry: Entry)] {
        var all = apps.map { (Subject.app($0.key), $0.value) } + sites.map { (Subject.site($0.key), $0.value) }
        all += domains.map { (Subject.domain($0.key), $0.value) }
        all += pages.compactMap { key, value in BrowserPage(rawValue: key).map { (Subject.page($0), value) } }
        return all
            .sorted { ($0.1.name.lowercased(), "\($0.0)") < ($1.1.name.lowercased(), "\($1.0)") }
            .map { (subject: $0.0, entry: $0.1) }
    }

    // MARK: Editing

    /// Stores an override for the stretch's website, else its app. An
    /// explicit `.uncategorized` is stored too, so it wins over a list that
    /// holds the item. Returns false when there is nothing to name.
    @discardableResult
    mutating func set(_ group: ActivityGroup, appID: String?, appName: String? = nil,
                      site: String?, url: String? = nil) -> Bool {
        switch Self.subject(appID: appID, site: site, url: url) {
        case .site(let host)?: sites[host] = Entry(group: group, name: host)
        case .app(let id)?: apps[id] = Entry(group: group, name: appName ?? id)
        case .domain?, .page?, nil: return false
        }
        return true
    }

    /// Stores an override for an explicit subject, as the Sort card does for
    /// a whole domain or a bucket of browser pages.
    mutating func set(_ group: ActivityGroup, subject: Subject, name: String) {
        let entry = Entry(group: group, name: name)
        switch subject {
        case .app(let id): apps[id] = entry
        case .site(let host): sites[host] = entry
        case .domain(let domain): domains[domain] = entry
        case .page(let page): pages[page.rawValue] = entry
        }
    }

    mutating func remove(_ subject: Subject) {
        switch subject {
        case .app(let id): apps[id] = nil
        case .site(let host): sites[host] = nil
        case .domain(let domain): domains[domain] = nil
        case .page(let page): pages[page.rawValue] = nil
        }
    }

    /// Drops what points at a category that is gone. A preset deleted and
    /// added back keeps its id, and would otherwise pick its old overrides up.
    mutating func removeCategory(_ id: String) {
        apps = apps.filter { $0.value.group != .category(id) }
        sites = sites.filter { $0.value.group != .category(id) }
        domains = domains.filter { $0.value.group != .category(id) }
        pages = pages.filter { $0.value.group != .category(id) }
    }

    /// Points what counted under `id` at `target`, for a merged category.
    mutating func moveCategory(_ id: String, to target: String) {
        for key in apps.keys where apps[key]?.group == .category(id) { apps[key]?.group = .category(target) }
        for key in sites.keys where sites[key]?.group == .category(id) { sites[key]?.group = .category(target) }
        for key in domains.keys where domains[key]?.group == .category(id) { domains[key]?.group = .category(target) }
        for key in pages.keys where pages[key]?.group == .category(id) { pages[key]?.group = .category(target) }
    }

    // MARK: Saved form

    private enum CodingKeys: String, CodingKey { case apps, sites, domains, pages }

    init() {}

    /// A saved entry that no longer decodes is dropped, not the rest with it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func entries(_ key: CodingKeys) throws -> [String: Entry] {
            let saved = try container.decodeIfPresent([String: Lossy].self, forKey: key) ?? [:]
            return saved.compactMapValues(\.entry)
        }
        apps = try entries(.apps)
        sites = try entries(.sites)
        // Absent in what older versions saved: those entries stay exact-host.
        domains = try entries(.domains)
        pages = try entries(.pages)
    }

    private struct Lossy: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
    }
}
