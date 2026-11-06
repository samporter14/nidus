//
//  ActivityDrill.swift
//  Nidus
//
//  What's inside an app's time: a browser's sites and each site's pages, or
//  a document app's files. Worked out from the same rows as the ranked lists,
//  so it adds up to them.
//

import Foundation

struct ActivityDrill: Identifiable, Equatable, Sendable {
    /// Time in the app with no site or name.
    static let unnamedID = "__unnamed__"
    /// Below this, unnamed time isn't worth a row.
    static let shortestUnnamed: TimeInterval = 60

    let id: String
    let name: String
    let seconds: TimeInterval
    /// A site's pages. Empty for a file or a page.
    var children: [ActivityDrill] = []

    /// By app id. An app with nothing named inside it has no entry.
    static func tree(_ rows: [FocusActivity]) -> [String: [ActivityDrill]] {
        var totals: [String: TimeInterval] = [:]
        var sites: [String: [String: [String: TimeInterval]]] = [:]
        var loose: [String: [String: TimeInterval]] = [:]
        for row in rows where row.seconds > 0 {
            totals[row.appID, default: 0] += row.seconds
            let site = row.site.flatMap { $0.isEmpty ? nil : $0 }
            let title = row.title.flatMap { $0.isEmpty ? nil : $0 }
            if let site {
                let page = ActivityTimeline.isDocumentService(site)
                    ? ActivityTimeline.documentName(title: title, site: site) : title
                sites[row.appID, default: [:]][site, default: [:]][page ?? "", default: 0] += row.seconds
            } else if let title {
                loose[row.appID, default: [:]][title, default: 0] += row.seconds
            }
        }
        var result: [String: [ActivityDrill]] = [:]
        for (appID, total) in totals {
            var inside = (sites[appID] ?? [:]).map { site, pages -> ActivityDrill in
                let named = pages.filter { !$0.key.isEmpty }
                return ActivityDrill(id: site, name: site, seconds: pages.values.reduce(0, +), children: ranked(named))
            }
            inside += ranked(loose[appID] ?? [:])
            guard !inside.isEmpty else { continue }
            let unnamed = total - inside.reduce(0) { $0 + $1.seconds }
            inside.sort(by: order)
            if unnamed >= shortestUnnamed {
                inside.append(ActivityDrill(id: unnamedID, name: "No name recorded", seconds: unnamed))
            }
            result[appID] = inside
        }
        return result
    }

    private static func ranked(_ values: [String: TimeInterval]) -> [ActivityDrill] {
        values.map { ActivityDrill(id: $0.key, name: $0.key, seconds: $0.value) }.sorted(by: order)
    }

    private static func order(_ a: ActivityDrill, _ b: ActivityDrill) -> Bool {
        a.seconds == b.seconds ? a.name < b.name : a.seconds > b.seconds
    }
}
