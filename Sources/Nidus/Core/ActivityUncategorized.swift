//
//  ActivityUncategorized.swift
//  Nidus
//
//  What the "Sort uncategorized" card on the Activity page offers: the apps
//  and websites whose time no group claims, longest first, each named the way
//  a "Count as" override is keyed (`ActivityOverrides.subject`). Choosing one
//  stores an override and nothing else, so sorting never touches what a
//  session blocks.
//
//  Left out:
//  - a browser with no page behind it (a new tab, a local page): counting the
//    browser itself would sweep every unmatched page into one group;
//  - anything that already has an override, "Leave" (explicit Uncategorized)
//    included, so a choice takes the item off the card for good.
//

import Foundation

struct ActivityUncategorizedItem: Identifiable, Equatable, Sendable {
    var subject: ActivityOverrides.Subject
    /// The host for a website, the app's name for an app.
    var name: String
    var appID: String?
    var appName: String?
    var site: String?
    var url: String?
    var seconds: TimeInterval

    var id: String {
        switch subject {
        case .app(let id): return "app:" + id
        case .site(let host): return "site:" + host
        }
    }

    var isWebsite: Bool {
        if case .site = subject { return true }
        return false
    }
}

enum ActivityUncategorized {
    /// Every item to sort, longest first (ties by name). `stretches` and
    /// `rows` together hold each second once, as `ActivityScope` keeps them.
    static func items(stretches: [FocusActivitySegment], rows: [FocusActivity] = [],
                      using categorizer: ActivityCategorizer,
                      overrides: ActivityOverrides) -> [ActivityUncategorizedItem] {
        var found: [ActivityOverrides.Subject: ActivityUncategorizedItem] = [:]
        // Many stretches share an app and page; each distinct one is judged once.
        var judged: [String: ActivityOverrides.Subject?] = [:]
        let all: [(String, String, String?, String?, TimeInterval)] =
            stretches.map { ($0.appID, $0.appName, $0.site, $0.url, $0.seconds) }
            + rows.map { ($0.appID, $0.appName, $0.site, nil, $0.seconds) }
        for (appID, appName, site, url, seconds) in all where seconds.isFinite && seconds > 0 {
            let key = appID + "\u{1}" + (url ?? site ?? "")
            let subject: ActivityOverrides.Subject?
            if let known = judged[key] {
                subject = known
            } else {
                subject = sortable(appID: appID, site: site, url: url, using: categorizer, overrides: overrides)
                judged[key] = .some(subject)
            }
            guard let subject else { continue }
            if found[subject] == nil {
                let name: String
                switch subject {
                case .site(let host): name = host
                case .app: name = appName.isEmpty ? appID : appName
                }
                found[subject] = ActivityUncategorizedItem(subject: subject, name: name, appID: appID, appName: appName,
                                                           site: site, url: url, seconds: 0)
            }
            found[subject]?.seconds += seconds
        }
        return found.values.sorted { ($1.seconds, $0.name) < ($0.seconds, $1.name) }
    }

    /// The subject to offer for one stretch, or nil when it counts somewhere
    /// already, has an override, or is a browser with no page.
    private static func sortable(appID: String, site: String?, url: String?,
                                 using categorizer: ActivityCategorizer,
                                 overrides: ActivityOverrides) -> ActivityOverrides.Subject? {
        guard categorizer.category(appID: appID, site: site, url: url) == nil,
              let subject = ActivityOverrides.subject(appID: appID, site: site, url: url) else { return nil }
        switch subject {
        case .app(let id):
            if FocusController.isBrowser(id) || overrides.apps[id] != nil { return nil }
        case .site(let host):
            if overrides.sites[host] != nil { return nil }
        }
        return subject
    }
}
