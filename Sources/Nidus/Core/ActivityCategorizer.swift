//
//  ActivityCategorizer.swift
//  Nidus
//
//  Which category a stretch of recorded activity counts under, worked out
//  when it is viewed. Day files hold apps and sites only, so a category the
//  user edits today also reads back over earlier days.
//
//  Rules, decided once:
//
//  - The groups are the Work group first, then the user's categories in
//    their own order. The first group that matches wins. Work goes first so
//    an explicit "Count as Work" beats a broad category rule (claude.ai in
//    Work and in AI chat is Work).
//  - A website is judged before an app. A browser stretch whose page matches
//    a group counts there, not under the browser; a page that matches
//    nothing falls back to the browser app's group, else Uncategorized.
//  - Websites are read by `WebsiteRule`, the blocker's own rule, exceptions
//    included: a page excepted from one group is read against the next.
//  - "Count as" is an `ActivityOverrides` entry, kept apart from the lists
//    above: a category's apps and websites are what a session blocks and are
//    only read here. See `category(appID:site:url:)` for the order.
//
//  What `site` holds: a stretch's `site` is either a bare domain
//  (`docs.google.com`, no `www.`, from `ActivityDomain`) or a service label
//  ("Google Docs", "Claude", "Microsoft Word", "Claude Science", "Capsid"),
//  never both. A label hides the host and a stretch's `url` has the page's
//  address, so the address is read first. A `FocusActivity` row has no `url`;
//  a label there is turned back into a page of that service
//  (`ActivityProbe.address(forService:)`). The two local labels have none and
//  are read by app alone.
//

import Foundation

/// One group's share of the time, for a chart or a list.
struct ActivityCategoryTotal: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var symbol: String
    var seconds: TimeInterval
    /// Of all the time counted, Uncategorized included. 0...1.
    var share: Double
}

struct ActivityCategorizer: Sendable {
    /// The Work group's id. Categories made by the user are UUIDs and the
    /// presets are words that are not this one.
    static let workID = "work"
    /// The id of the entry for time no group claims.
    static let uncategorizedID = "uncategorized"
    static let uncategorizedName = "Uncategorized"
    static let uncategorizedSymbol = "circle.dashed"

    private struct Group: Sendable {
        let id: String
        let name: String
        let symbol: String
        let apps: Set<String>
        /// nil when the group lists no websites.
        let rule: WebsiteRule?

        init(_ category: FocusCategory) {
            id = category.id
            name = category.name
            symbol = category.symbol
            apps = Set(category.apps.map(\.bundleID))
            rule = category.websites.isEmpty
                ? nil
                : WebsiteRule(mode: .block, domains: category.websites, exceptions: category.websiteExceptions)
        }
    }

    /// Work first, then the categories in order.
    private let groups: [Group]
    private let overrides: ActivityOverrides

    init(categories: [FocusCategory], work: FocusCategory, overrides: ActivityOverrides = ActivityOverrides()) {
        var work = work
        work.id = Self.workID
        groups = ([work] + categories.filter { $0.id != Self.workID }).map(Group.init)
        self.overrides = overrides
    }

    // MARK: One stretch

    /// The id of the group a stretch counts under: `workID`, a category's id,
    /// or nil for Uncategorized. `url` is the stretch's address when it has
    /// one; it is preferred over `site`.
    ///
    /// Order, first hit wins:
    ///  1. an override on the page's host;
    ///  2. a group whose website rules match the page;
    ///  3. an override on the app;
    ///  4. a group that lists the app;
    ///  5. Uncategorized.
    /// A page is judged before its app, so a browser's own override or list
    /// never beats a page that has a category of its own. An override whose
    /// category is gone is skipped, as if it were not there. An override to
    /// Uncategorized is a hit: it beats a list that holds the item.
    func category(appID: String, site: String?, url: String? = nil) -> String? {
        let address = Self.address(site: site, url: url)
        if !overrides.sites.isEmpty, let address, let host = ActivityDomain.site(from: address),
           let hit = resolve(overrides.sites[host]) {
            return hit
        }
        if let address, let match = groups.first(where: { $0.rule?.blocks(address) == true }) {
            return match.id
        }
        if let hit = resolve(overrides.apps[appID]) { return hit }
        return groups.first { $0.apps.contains(appID) }?.id
    }

    /// The same, as a group.
    func group(appID: String?, site: String?, url: String? = nil) -> ActivityGroup {
        ActivityGroup(id: category(appID: appID ?? "", site: site, url: url))
    }

    /// An override's id, with nil inside for Uncategorized; nil outside when
    /// there is no override or its category no longer exists.
    private func resolve(_ entry: ActivityOverrides.Entry?) -> String?? {
        switch entry?.group {
        case nil: return nil
        case .work?: return .some(Self.workID)
        case .uncategorized?: return .some(nil)
        case .category(let id)?:
            if id == Self.workID { return .some(Self.workID) }
            return groups.contains { $0.id == id } ? .some(id) : nil
        }
    }

    /// The page a site or address names, as a URL the website rules read.
    /// nil when there is none to read (an app, a local tab).
    static func address(site: String?, url: String?) -> String? {
        if let url, DomainMatcher.isWebPage(url) { return url }
        guard let site else { return nil }
        if let service = ActivityProbe.address(forService: site) { return service }
        return ActivityDomain.isDomain(site) ? "https://" + site : nil
    }

    // MARK: Totals

    /// Time per group over a day's stretches, longest first, Uncategorized
    /// as its own entry. Groups with no time are left out.
    func totals(of stretches: [FocusActivitySegment]) -> [ActivityCategoryTotal] {
        totals(stretches.lazy.map { ($0.appID, $0.site, $0.url, $0.seconds) })
    }

    /// The same over totals rows. These carry no address, so a site is read
    /// as its domain (or its service's page).
    func totals(of rows: [FocusActivity]) -> [ActivityCategoryTotal] {
        totals(rows.lazy.map { ($0.appID, $0.site, nil, $0.seconds) })
    }

    private func totals(_ items: some Sequence<(String, String?, String?, TimeInterval)>) -> [ActivityCategoryTotal] {
        // Many stretches share an app and page; the matcher parses a URL for
        // every group, so each distinct one is read once.
        var seen: [String: String?] = [:]
        var seconds: [String: TimeInterval] = [:]
        var uncategorized: TimeInterval = 0
        for (appID, site, url, time) in items where time.isFinite && time > 0 {
            let key = appID + "\u{1}" + (url ?? site ?? "")
            let id: String?
            if let known = seen[key] {
                id = known
            } else {
                id = category(appID: appID, site: site, url: url)
                seen[key] = .some(id)
            }
            if let id { seconds[id, default: 0] += time } else { uncategorized += time }
        }
        let all = seconds.values.reduce(uncategorized, +)
        guard all > 0 else { return [] }
        var result = groups.compactMap { group -> ActivityCategoryTotal? in
            guard let time = seconds[group.id] else { return nil }
            return ActivityCategoryTotal(id: group.id, name: group.name, symbol: group.symbol,
                                         seconds: time, share: time / all)
        }
        if uncategorized > 0 {
            result.append(ActivityCategoryTotal(id: Self.uncategorizedID, name: Self.uncategorizedName,
                                                symbol: Self.uncategorizedSymbol,
                                                seconds: uncategorized, share: uncategorized / all))
        }
        return result.sorted { ($1.seconds, $0.name) < ($0.seconds, $1.name) }
    }
}
