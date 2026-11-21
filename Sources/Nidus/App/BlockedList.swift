import Foundation

/// What the popover's session would block, spelled out: the apps and websites
/// of the plan it already resolves, grouped by category, and how that differs
/// from a saved setup. Pure values and functions with no UI and no icons, and
/// nothing here runs until the person opens "Show what's blocked"
/// (`LazyBlockedList`), so a collapsed popover holds none of it.
struct BlockedList: Equatable {
    struct App: Equatable, Identifiable {
        var bundleID: String
        var name: String
        /// On AppBlocker's exempt list, Nidus itself, or opened by the session:
        /// listed, but the blocker never touches it.
        var neverBlocked: Bool
        var id: String { bundleID }
    }

    struct Section: Equatable, Identifiable {
        var title: String
        var apps: [App]
        var websites: [String]
        var id: String { title }
    }

    var mode: SessionPlan.Mode
    var sections: [Section]
    /// "Differs from setup 'X': adds A, B; removes C", or nil.
    var differenceLine: String?

    var isEmpty: Bool { sections.isEmpty }

    /// The title for items the plan holds that no chosen category names.
    static let otherTitle = "Other"

    /// The plan's apps and websites under the categories that bring them in.
    /// An item in two categories shows under the first. Empty categories are
    /// left out. Marks are made in block mode only: in allow mode the listed
    /// apps are the ones let through, so "never blocked" would say nothing.
    static func sections(plan: SessionPlan, categories: [FocusCategory],
                         exempt: Set<String> = AppBlocker.exempt,
                         ownBundleID: String? = Bundle.main.bundleIdentifier) -> [Section] {
        let neverBlocked = Set(plan.launchApps).union(exempt).union(ownBundleID.map { [$0] } ?? [])
        let wantedApps = Set(plan.apps), wantedSites = Set(plan.websites)
        var seenApps = Set<String>(), seenSites = Set<String>()
        var result: [Section] = []

        func app(_ id: String, _ name: String) -> App {
            App(bundleID: id, name: name, neverBlocked: plan.mode == .block && neverBlocked.contains(id))
        }
        for category in categories {
            let apps = category.apps.filter { wantedApps.contains($0.bundleID) && seenApps.insert($0.bundleID).inserted }
                .map { app($0.bundleID, $0.name) }
            let sites = category.websites.filter { wantedSites.contains($0) && seenSites.insert($0).inserted }
            if !apps.isEmpty || !sites.isEmpty {
                result.append(Section(title: category.name, apps: apps, websites: sites))
            }
        }
        let strayApps = plan.apps.filter { seenApps.insert($0).inserted }.map { app($0, $0) }
        let straySites = plan.websites.filter { seenSites.insert($0).inserted }
        if !strayApps.isEmpty || !straySites.isEmpty {
            result.append(Section(title: otherTitle, apps: strayApps, websites: straySites))
        }
        return result
    }

    // MARK: Difference from a saved setup

    /// The apps (bundle ID to name) and websites a setup's live categories hold.
    struct Items: Equatable {
        var apps: [String: String] = [:]
        var websites: Set<String> = []
        var mode: SessionPlan.Mode = .block

        init(mode: SessionPlan.Mode, categories: [FocusCategory]) {
            self.mode = mode
            for category in categories {
                for app in category.apps { apps[app.bundleID] = app.name }
                websites.formUnion(category.websites)
            }
        }

        init(plan: SessionPlan, categories: [FocusCategory]) {
            self.init(mode: plan.mode, categories: categories)
            apps = apps.filter { plan.apps.contains($0.key) }
            websites = websites.intersection(plan.websites)
            for id in plan.apps where apps[id] == nil { apps[id] = id }
            websites.formUnion(plan.websites)
        }

        init(setup: FocusSetup, categories: [FocusCategory]) {
            let live = Set(setup.liveCategoryIDs(in: categories))
            self.init(mode: setup.mode, categories: categories.filter { live.contains($0.id) })
        }

        var count: Int { apps.count + websites.count }

        func overlap(with other: Items) -> Int {
            Set(apps.keys).intersection(other.apps.keys).count + websites.intersection(other.websites).count
        }

        /// Same mode and same apps and sites: no difference worth a line.
        func matches(_ other: Items) -> Bool {
            mode == other.mode && Set(apps.keys) == Set(other.apps.keys) && websites == other.websites
        }

        func distance(to other: Items) -> Int {
            count + other.count - 2 * overlap(with: other) + (mode == other.mode ? 0 : 1)
        }
    }

    /// Which setup to compare with. A setup being adjusted ("use as starting
    /// point") is the one the popover was loaded from, so it is the one. With
    /// none loaded: nothing when a saved setup matches exactly, else the saved
    /// setup nearest the selection, and only if it shares at least one item
    /// with it (a setup with nothing in common says nothing useful).
    static func comparisonSetup(current: Items, setups: [FocusSetup], loadedSetupID: UUID?,
                                categories: [FocusCategory]) -> FocusSetup? {
        if let loadedSetupID, let loaded = setups.first(where: { $0.id == loadedSetupID }) { return loaded }
        let candidates = setups.map { ($0, Items(setup: $0, categories: categories)) }
        if candidates.contains(where: { current.matches($0.1) }) { return nil }
        let near = candidates.filter { current.count == 0 || current.overlap(with: $0.1) > 0 }
        return near.min { current.distance(to: $0.1) < current.distance(to: $1.1) }?.0
    }

    /// "Differs from setup 'X': adds A, B; removes C". Nil when nothing differs.
    static func differenceLine(setupName: String, current: Items, saved: Items, limit: Int = 4) -> String? {
        var parts: [String] = []
        if current.mode != saved.mode {
            parts.append(current.mode == .allow ? "uses an allow list instead of a block list"
                                                : "uses a block list instead of an allow list")
        }
        let added = names(current, minus: saved), removed = names(saved, minus: current)
        if !added.isEmpty { parts.append("adds \(list(added, limit: limit))") }
        if !removed.isEmpty { parts.append("removes \(list(removed, limit: limit))") }
        guard !parts.isEmpty else { return nil }
        return "Differs from setup '\(setupName)': " + parts.joined(separator: "; ")
    }

    private static func names(_ items: Items, minus other: Items) -> [String] {
        let apps = items.apps.filter { other.apps[$0.key] == nil }.map(\.value)
        let sites = items.websites.subtracting(other.websites)
        return apps.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            + sites.sorted()
    }

    private static func list(_ names: [String], limit: Int) -> String {
        names.count <= limit ? names.joined(separator: ", ")
            : names.prefix(limit).joined(separator: ", ") + " and \(names.count - limit) more"
    }

    // MARK: Building

    /// Everything the disclosure shows, from the plan the popover resolves.
    static func make(plan: SessionPlan, categories: [FocusCategory], setups: [FocusSetup],
                     loadedSetupID: UUID?, allCategories: [FocusCategory]) -> BlockedList {
        let current = Items(plan: plan, categories: categories)
        var line: String?
        if let setup = comparisonSetup(current: current, setups: setups, loadedSetupID: loadedSetupID,
                                       categories: allCategories) {
            line = differenceLine(setupName: setup.displayName, current: current,
                                  saved: Items(setup: setup, categories: allCategories))
        }
        return BlockedList(mode: plan.mode, sections: sections(plan: plan, categories: categories), differenceLine: line)
    }
}

/// The disclosure's state. The list exists only while expanded: opening builds
/// it, closing (or the popover going away) drops it. `build` is not called
/// while collapsed.
struct LazyBlockedList: Equatable {
    private(set) var expanded = false
    private(set) var list: BlockedList?

    mutating func setExpanded(_ value: Bool, build: () -> BlockedList?) {
        expanded = value
        list = value ? build() : nil
    }

    mutating func reset() { expanded = false; list = nil }
}
