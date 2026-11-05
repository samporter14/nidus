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

    /// What an override is about: an app by bundle id, or a website by its
    /// bare host. A website override covers that exact host only, not its
    /// subdomains: a rule on `google.com` should not pull `docs.google.com`
    /// along when it is counted on its own.
    enum Subject: Hashable, Sendable {
        case app(String)
        case site(String)
    }

    var apps: [String: Entry] = [:]
    var sites: [String: Entry] = [:]

    var isEmpty: Bool { apps.isEmpty && sites.isEmpty }

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
        let all = apps.map { (Subject.app($0.key), $0.value) } + sites.map { (Subject.site($0.key), $0.value) }
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
        case nil: return false
        }
        return true
    }

    mutating func remove(_ subject: Subject) {
        switch subject {
        case .app(let id): apps[id] = nil
        case .site(let host): sites[host] = nil
        }
    }

    /// Drops what points at a category that is gone. A preset deleted and
    /// added back keeps its id, and would otherwise pick its old overrides up.
    mutating func removeCategory(_ id: String) {
        apps = apps.filter { $0.value.group != .category(id) }
        sites = sites.filter { $0.value.group != .category(id) }
    }

    /// Points what counted under `id` at `target`, for a merged category.
    mutating func moveCategory(_ id: String, to target: String) {
        for key in apps.keys where apps[key]?.group == .category(id) { apps[key]?.group = .category(target) }
        for key in sites.keys where sites[key]?.group == .category(id) { sites[key]?.group = .category(target) }
    }

    // MARK: Saved form

    private enum CodingKeys: String, CodingKey { case apps, sites }

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
    }

    private struct Lossy: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
    }
}
