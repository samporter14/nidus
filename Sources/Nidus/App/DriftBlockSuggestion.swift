//
//  DriftBlockSuggestion.swift
//  Nidus
//
//  "You drifted to reddit.com 6 times this week. Add it to your block list?":
//  a quiet line in the idle popover, below the save-a-setup offer. The count
//  is the drift chains Activity already finds (a few minutes on something,
//  then a few minutes on a distraction), by what they landed on, over the
//  last 7 days. It reads the cached day digests, and only when the popover
//  opens, at most every few minutes; nothing polls.
//
//  Add puts the item in the popover's selection (a category of its own kept
//  for this) and never edits a saved setup. "Don't ask again" is per item.
//

import Foundation

/// An app or a site, as a drift target.
struct DriftItem: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case app, site }
    var kind: Kind
    /// A bundle identifier or a host.
    var value: String
    /// What to call it: the app's name or the host.
    var name: String

    /// What dismissals are kept under.
    var key: String { kind.rawValue + ":" + value }
}

struct DriftBlockSuggestion: Equatable, Sendable {
    var item: DriftItem
    var count: Int

    var message: String { "You drifted to \(item.name) \(count) times this week. Add it to your block list?" }
}

enum DriftBlockSuggester {
    static let threshold = 5
    static let days = 7

    /// The day keys of the window, today last.
    static func windowKeys(now: Date, calendar: Calendar) -> [String] {
        (0..<days).compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: now).map { ActivityDayLog.key(for: $0, calendar: calendar) }
        }
    }

    /// Whether `blocked` already stops `item`: an app by identifier, a site
    /// by its host or a parent domain, as the browser blocker matches.
    static func isBlocked(_ item: DriftItem, apps: Set<String>, websites: [String]) -> Bool {
        switch item.kind {
        case .app: return apps.contains(item.value)
        case .site: return websites.contains { item.value == $0 || item.value.hasSuffix("." + $0) }
        }
    }

    /// The one item to offer: the distracting target with the most drifts in
    /// the window (then the name), if it reached the threshold and is neither
    /// dismissed nor already blocked. `byDay` is chains by day key.
    static func suggestion(byDay: [String: [ActivityDriftChain]], now: Date, calendar: Calendar,
                           categorizer: ActivityCategorizer, dismissed: Set<String>,
                           blockedApps: Set<String>, blockedWebsites: [String]) -> DriftBlockSuggestion? {
        var counts: [DriftItem: Int] = [:]
        for key in windowKeys(now: now, calendar: calendar) {
            for chain in byDay[key] ?? [] where categorizer.isDistracting(group: chain.category) {
                let item = chain.targetAppID.map { DriftItem(kind: .app, value: $0, name: chain.target) }
                    ?? DriftItem(kind: .site, value: chain.target, name: chain.target)
                counts[item, default: 0] += chain.count
            }
        }
        return counts
            .filter { $0.value >= threshold && !dismissed.contains($0.key.key)
                && !isBlocked($0.key, apps: blockedApps, websites: blockedWebsites) }
            .map { DriftBlockSuggestion(item: $0.key, count: $0.value) }
            .min { $0.count != $1.count ? $0.count > $1.count : ($0.item.name, $0.item.key) < ($1.item.name, $1.item.key) }
    }

    /// The category Add keeps its items in.
    static let categoryID = "drift-additions"

    /// `categories` and `selection` with `item` added: to the category of its
    /// own, made on first use, which is then selected. Nothing else changes.
    static func adding(_ item: DriftItem, categories: [FocusCategory], selection: [String])
        -> (categories: [FocusCategory], selection: [String]) {
        var categories = categories
        if !categories.contains(where: { $0.id == categoryID }) {
            categories.append(FocusCategory(id: categoryID, name: "Added from drift", symbol: "arrow.uturn.right",
                                            apps: [], websites: []))
        }
        if let index = categories.firstIndex(where: { $0.id == categoryID }) {
            switch item.kind {
            case .app:
                if !categories[index].apps.contains(where: { $0.bundleID == item.value }) {
                    categories[index].apps.append(BlockedApp(bundleID: item.value, name: item.name))
                }
            case .site:
                if !categories[index].websites.contains(item.value) { categories[index].websites.append(item.value) }
            }
        }
        var selection = selection
        if !selection.contains(categoryID) { selection.append(categoryID) }
        return (categories, selection)
    }
}

// MARK: - The model's side

extension NidusModel.Key {
    static let dismissedDriftSuggestions = "dismissedDriftSuggestions"
}

extension NidusModel {
    private var dismissedDriftSuggestions: [String] {
        get { preferenceList(Key.dismissedDriftSuggestions) }
        set { setPreference(newValue, Key.dismissedDriftSuggestions) }
    }

    /// Computes again from the cached day digests, off the main thread, unless
    /// it did so a few minutes ago. Called when the idle popover appears.
    func refreshDriftSuggestion(now: Date = Date(), force: Bool = false) async {
        guard recordsHistory, setupDraft == nil, let recorder = controller?.activityRecorder else {
            if driftSuggestion != nil { driftSuggestion = nil }
            return
        }
        if !force, let last = driftComputedAt, now.timeIntervalSince(last) < 5 * 60 { return }
        driftComputedAt = now
        let calendar = Calendar.current
        let keys = DriftBlockSuggester.windowKeys(now: now, calendar: calendar)
        let today = ActivityDayLog.key(for: now, calendar: calendar)
        let excluded = activityExcludedApps
        let signature = ActivityDigestSignature(version: controller?.historyVersion ?? 0, excluded: excluded, work: workGroup,
                                                categories: categories, overrides: activityOverrides)
        let categorizer = ActivityCategorizer(categories: categories, work: workGroup, overrides: activityOverrides)
        let live = recorder.isRecording ? recorder.today() : await recorder.store.load(days: [today]).first
        let digests = driftDigests
        let perDay = await digests.chains(days: keys, today: today, live: live?.hiding(excluded), signature: signature,
                                          categorizer: categorizer, calendar: calendar) { missing in
            await recorder.store.load(days: missing).map { $0.hiding(excluded) }
        }
        let apps = Set(composerCategories.flatMap { $0.apps.map(\.bundleID) })
        let sites = composerCategories.flatMap(\.websites)
        let found = DriftBlockSuggester.suggestion(byDay: perDay, now: now, calendar: calendar, categorizer: categorizer,
                                                   dismissed: Set(dismissedDriftSuggestions), blockedApps: apps,
                                                   blockedWebsites: sites)
        if found != driftSuggestion { driftSuggestion = found }
    }

    /// Whether the idle popover offers it now. Never while a setup is open
    /// in the composer, and re-checked against the current selection.
    func offersDriftSuggestion() -> Bool {
        guard recordsHistory, setupDraft == nil, let suggestion = driftSuggestion else { return false }
        let apps = Set(composerCategories.flatMap { $0.apps.map(\.bundleID) })
        return !DriftBlockSuggester.isBlocked(suggestion.item, apps: apps, websites: composerCategories.flatMap(\.websites))
    }

    /// Adds the item to the popover's selection. Saved setups are untouched.
    func acceptDriftSuggestion() {
        guard let item = driftSuggestion?.item else { return }
        let result = DriftBlockSuggester.adding(item, categories: categories, selection: selectedCategoryIDs)
        categories = result.categories
        selectedCategoryIDs = result.selection
        driftSuggestion = nil
    }

    /// "Don't ask again" for this item.
    func dismissDriftSuggestion() {
        guard let item = driftSuggestion?.item else { return }
        if !dismissedDriftSuggestions.contains(item.key) { dismissedDriftSuggestions.append(item.key) }
        driftSuggestion = nil
        driftComputedAt = nil
    }
}

extension ActivityDigestCache {
    /// Each day's drift chains, from the cached day digests.
    func chains(days: [String], today: String, live: ActivityDayLog?, signature: ActivityDigestSignature,
                categorizer: ActivityCategorizer, calendar: Calendar,
                load: @Sendable ([String]) async -> [ActivityDayLog]) async -> [String: [ActivityDriftChain]] {
        var result: [String: [ActivityDriftChain]] = [:]
        for day in days {
            let digest = await self.digest(grid: [], week: [], chains: [day], today: today, live: live, signature: signature,
                                           categorizer: categorizer, calendar: calendar, load: load)
            result[day] = Array(digest.chains.values)
        }
        return result
    }
}
