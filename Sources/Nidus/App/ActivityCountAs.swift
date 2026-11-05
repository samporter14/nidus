//
//  ActivityCountAs.swift
//  Nidus
//
//  "Count as" on a ranked row: move the app or website behind it to Work, to
//  one of the categories, or out of them all. The menu is the same on the
//  Activity page and in the popover.
//

import SwiftUI

/// What a ranked row moves when it is counted as something else.
struct ActivityCountTarget: Equatable {
    var appID: String?
    var appName: String?
    var site: String?
    var url: String?

    /// Apps count as themselves. A website counts as its site; one that is
    /// only a label with no page behind it counts as the app it was in. A
    /// document counts as its site if it has one, else its app. Categories
    /// are not counted as anything.
    init?(rank: ActivityRank, kind: ActivityListKind) {
        switch kind {
        case .apps:
            self.init(appID: rank.id, appName: rank.name, site: nil, url: nil)
        case .websites:
            self.init(appID: rank.sourceAppID, appName: rank.sourceAppName, site: rank.id, url: rank.url)
        case .documents:
            self.init(appID: rank.appID, appName: rank.appName, site: rank.site, url: rank.url)
        case .categories:
            return nil
        }
    }

    init?(appID: String?, appName: String?, site: String?, url: String?) {
        guard appID != nil || site != nil else { return nil }
        self.appID = appID
        self.appName = appName
        self.site = site
        self.url = url
    }

    /// What the menu says is being moved.
    var label: String {
        let isPage = ActivityCategorizer.address(site: site, url: url) != nil
        return (isPage ? site : nil) ?? appName ?? appID ?? site ?? ""
    }
}

struct ActivityCountAsMenu: View {
    @ObservedObject var model: NidusModel
    let target: ActivityCountTarget
    /// Called after the move, for a view that holds its own copy of the day.
    var counted: () -> Void = {}

    var body: some View {
        let current = model.activityAssignment(appID: target.appID, site: target.site, url: target.url)
        Menu("Count \(target.label) as") {
            choice(model.workGroup.name, .work, current)
            ForEach(model.categories) { choice($0.name, .category($0.id), current) }
            choice(ActivityCategorizer.uncategorizedName, .uncategorized, current)
            Divider()
            Button("Blocking categories also block this in future sessions.") {}
                .disabled(true)
        }
    }

    /// A checkmark on the group it counts under now.
    private func choice(_ name: String, _ group: ActivityGroup, _ current: ActivityGroup) -> some View {
        Toggle(name, isOn: Binding(get: { current == group }, set: { _ in move(to: group) }))
    }

    private func move(to group: ActivityGroup) {
        model.countActivity(appID: target.appID, appName: target.appName, site: target.site, url: target.url, as: group)
        counted()
    }
}

extension View {
    /// Adds "Count as" to a row's context menu; a row with nothing to move gets none.
    @ViewBuilder
    func activityCountAs(model: NidusModel, target: ActivityCountTarget?, counted: @escaping () -> Void = {}) -> some View {
        if let target {
            contextMenu { ActivityCountAsMenu(model: model, target: target, counted: counted) }
        } else {
            self
        }
    }
}
