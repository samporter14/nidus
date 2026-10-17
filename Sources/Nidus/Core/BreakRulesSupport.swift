//
//  BreakRulesSupport.swift
//  Nidus
//
//  Working with a break's rules: choosing them from the categories, and
//  saying what they keep blocked. `BreakRules` itself is plain data
//  (SessionPlanParts.swift); a break's rules are the apps and websites
//  themselves, not category ids, so a category edited later changes nothing
//  about a plan that already holds them. docs/design-0.4.md, "Breaks".
//
//  No DroppyKit import: this file also compiles into the tests.
//

import Foundation

extension BreakRules {
    /// A category is on when it has something in it and every one of its apps
    /// and websites is blocked here.
    func covers(_ category: FocusCategory) -> Bool {
        guard !category.isEmpty else { return false }
        return category.apps.allSatisfy { apps.contains($0.bundleID) } && category.websites.allSatisfy { websites.contains($0) }
    }

    func coveredCategories(in categories: [FocusCategory]) -> [FocusCategory] {
        categories.filter(covers)
    }

    /// These rules with a category turned on or off. Turning one off keeps
    /// whatever another category that is on still holds, so two categories
    /// that share a website don't pull each other off.
    func setting(_ category: FocusCategory, on: Bool, in categories: [FocusCategory]) -> BreakRules {
        var result = self
        if on {
            for app in category.apps where !result.apps.contains(app.bundleID) { result.apps.append(app.bundleID) }
            for site in category.websites where !result.websites.contains(site) { result.websites.append(site) }
            return result
        }
        let others = coveredCategories(in: categories).filter { $0.id != category.id }
        let keptApps = Set(others.flatMap { $0.apps.map(\.bundleID) })
        let keptSites = Set(others.flatMap(\.websites))
        let ownApps = Set(category.apps.map(\.bundleID))
        let ownSites = Set(category.websites)
        result.apps.removeAll { ownApps.contains($0) && !keptApps.contains($0) }
        result.websites.removeAll { ownSites.contains($0) && !keptSites.contains($0) }
        return result
    }

    /// The apps and websites that no category on here accounts for: the ones
    /// added one by one.
    func extras(in categories: [FocusCategory]) -> (apps: [String], websites: [String]) {
        let covered = coveredCategories(in: categories)
        let coveredApps = Set(covered.flatMap { $0.apps.map(\.bundleID) })
        let coveredSites = Set(covered.flatMap(\.websites))
        return (apps.filter { !coveredApps.contains($0) }, websites.filter { !coveredSites.contains($0) })
    }

    func adding(apps bundleIDs: [String]) -> BreakRules {
        var result = self
        for id in bundleIDs where !result.apps.contains(id) { result.apps.append(id) }
        return result
    }

    /// With a website added as a rule, normalized as a category's are. Unchanged
    /// for what is not a web address.
    func adding(website text: String) -> BreakRules {
        guard let site = FocusCategory.domain(from: text), !websites.contains(site) else { return self }
        var result = self
        result.websites.append(site)
        return result
    }

    func removing(app bundleID: String) -> BreakRules {
        var result = self
        result.apps.removeAll { $0 == bundleID }
        return result
    }

    func removing(website: String) -> BreakRules {
        var result = self
        result.websites.removeAll { $0 == website }
        return result
    }

    /// Rules as the reminder field writes them: bounded, and nil when blank.
    func settingReminder(_ text: String) -> BreakRules {
        var result = self
        let bounded = String(text.prefix(Self.reminderLimit))
        result.reminder = bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bounded
        return result
    }

    // MARK: Saying what they block

    /// What stays blocked, as names: the categories that are on, then the
    /// other apps, then the other websites. nil when nothing is blocked.
    func blockedNames(categories: [FocusCategory], appName: (String) -> String) -> [String]? {
        guard !isUnrestricted else { return nil }
        let extra = extras(in: categories)
        return coveredCategories(in: categories).map(\.name) + extra.apps.map(appName) + extra.websites
    }

    /// "Social and x.com stay blocked until 10:40", or nil for a break that
    /// blocks nothing. `until` is the time as the surface words it.
    func stayBlockedLine(categories: [FocusCategory], appName: (String) -> String, until: String) -> String? {
        guard let names = blockedNames(categories: categories, appName: appName) else { return nil }
        let list = Self.list(names)
        let verb = names.count == 1 ? "stays" : "stay"
        return "\(list.text) \(verb) blocked until \(until)"
    }

    /// "Social", "Social and x.com", "Social, Slack and x.com", and past
    /// three, the first three and a count.
    static func list(_ names: [String]) -> (text: String, count: Int) {
        switch names.count {
        case 0: return ("Nothing", 0)
        case 1: return (names[0], 1)
        case 2: return ("\(names[0]) and \(names[1])", 2)
        case 3: return ("\(names[0]), \(names[1]) and \(names[2])", 3)
        default: return ("\(names[0]), \(names[1]), \(names[2]) and \(names.count - 3) more", names.count)
        }
    }
}
