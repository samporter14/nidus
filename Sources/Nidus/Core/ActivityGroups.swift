//
//  ActivityGroups.swift
//  Nidus
//
//  The groups time is counted under, as one value: the Work group and the
//  user's categories, and how "Count as" moves an app or a website between
//  them. Pure, so it is tested without a model.
//
//  The groups are the blocking categories on purpose, not a second list:
//  moving a site out of Social also stops the next session blocking it,
//  and moving one into a category makes the next session block it. Work is
//  held apart and is never in a blocking plan.
//

import Foundation

/// Where an app or website counts.
enum ActivityGroup: Equatable, Sendable {
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
}

struct ActivityGroups: Equatable, Sendable {
    var work: FocusCategory
    var categories: [FocusCategory]

    var categorizer: ActivityCategorizer { ActivityCategorizer(categories: categories, work: work) }

    /// The group a stretch with this app and page counts under now.
    func assignment(appID: String?, site: String?, url: String? = nil) -> ActivityGroup {
        ActivityGroup(id: categorizer.category(appID: appID ?? "", site: site, url: url))
    }

    /// Takes the app or website out of every group that lists it, then lists
    /// it in `group`. A website is written as its host, which also covers its
    /// subdomains, as any website rule does. Where a broader rule you cannot
    /// take apart covers it (a parent domain such as `google.com`, or a path
    /// rule), the group gets an exception for the host instead, so it stops
    /// matching without losing the rest of its list. A category that does not
    /// exist leaves everything as it was.
    mutating func count(appID: String?, appName: String? = nil, site: String?, url: String? = nil,
                        as group: ActivityGroup) {
        if case .category(let id) = group, !categories.contains(where: { $0.id == id }) { return }
        guard let item = target(appID: appID, site: site, url: url) else { return }
        func edit(_ category: inout FocusCategory, adding: Bool) {
            switch item {
            case .app(let id):
                category.apps.removeAll { $0.bundleID == id }
                if adding { category.apps.append(BlockedApp(bundleID: id, name: appName ?? id)) }
            case .site(let host, let address):
                if adding { Self.list(host, address: address, in: &category) }
                else { Self.unlist(host, address: address, in: &category) }
            }
        }
        func isTarget(_ id: String) -> Bool {
            switch group {
            case .work: return id == ActivityCategorizer.workID
            case .category(let target): return id == target
            case .uncategorized: return false
            }
        }
        for index in categories.indices {
            if isTarget(categories[index].id) { edit(&categories[index], adding: true) }
            else { edit(&categories[index], adding: false) }
        }
        work.id = ActivityCategorizer.workID
        edit(&work, adding: group == .work)
    }

    // MARK: Items

    private enum Item {
        case app(String)
        /// The host to edit by, and the address to test coverage with.
        case site(host: String, address: String)
    }

    /// A website when there is a host to name, else the app.
    private func target(appID: String?, site: String?, url: String?) -> Item? {
        if let address = ActivityCategorizer.address(site: site, url: url), let host = ActivityDomain.site(from: address) {
            return .site(host: host, address: address)
        }
        return appID.map { .app($0) }
    }

    private static func isHost(_ entry: WebsiteEntry, _ host: String) -> Bool {
        entry.segments.isEmpty && (entry.host == host || entry.host == "www." + host)
    }

    private static func root(of host: String) -> String { "https://" + host + "/" }

    /// Drops the host's own entries, then, if a broader rule still covers it,
    /// an exception for the host.
    private static func unlist(_ host: String, address: String, in category: inout FocusCategory) {
        category.websites.removeAll { WebsiteEntry(stored: $0).map { isHost($0, host) } ?? false }
        guard DomainMatcher(category.websites).matches(address) || DomainMatcher(category.websites).matches(root(of: host)),
              case .success(let draft) = WebsiteException.draft(from: root(of: host), kind: .subtree),
              !category.websiteExceptions.contains(draft.exception) else { return }
        category.websiteExceptions.append(draft.exception)
    }

    /// Lists the host unless a rule already covers it, and takes back any
    /// exception that would hold it out.
    private static func list(_ host: String, address: String, in category: inout FocusCategory) {
        if case .success(let draft) = WebsiteException.draft(from: root(of: host), kind: .subtree) {
            category.websiteExceptions.removeAll { $0 == draft.exception }
        }
        let rule = DomainMatcher(category.websites)
        guard !rule.matches(address), !rule.matches(root(of: host)) else { return }
        category.websites.append(host)
    }
}
