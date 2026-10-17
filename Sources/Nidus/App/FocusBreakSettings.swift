//
//  FocusBreakSettings.swift
//  Nidus
//
//  Settings' defaults for what a break keeps blocked, and the exceptions a
//  session takes from its categories. docs/design-0.4.md, "Breaks" and
//  "Website exceptions".
//

import Foundation

extension NidusModel.Key {
    static let defaultBreakRules = "defaultBreakRules"
}

extension NidusModel {
    /// What a break keeps blocked when a setup doesn't say. nil: nothing, the
    /// unrestricted break every version before 0.4 had.
    var defaultBreakRules: BreakRules? {
        get {
            let rules = preference(Key.defaultBreakRules, default: BreakRules?.none)
            return rules?.isUnrestricted == false || rules?.displayReminder != nil ? rules : nil
        }
        set { setPreference(newValue, Key.defaultBreakRules) }
    }

    /// The exceptions of the chosen categories, then the request's own, each
    /// once. Block mode only: the caller passes none for an allow list.
    func websiteExceptions(for categories: [FocusCategory], adding extra: [WebsiteException]) -> [WebsiteException] {
        var all: [WebsiteException] = []
        for exception in categories.flatMap(\.websiteExceptions) + extra where !all.contains(exception) {
            all.append(exception)
        }
        return all
    }
}
