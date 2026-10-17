//
//  FocusBreakSettings.swift
//  Nidus
//
//  Settings' defaults for what a break keeps blocked, and the exceptions a
//  session takes from its categories. docs/design-0.4.md, "Breaks" and
//  "Website exceptions".
//

import Foundation
import SwiftUI

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

    /// The default rules as the editor holds them: always a value, stored as
    /// nil again once there is nothing in it.
    var defaultBreakRulesBinding: Binding<BreakRules> {
        Binding(
            get: { self.defaultBreakRules ?? BreakRules() },
            set: { self.defaultBreakRules = $0.isUnrestricted && $0.displayReminder == nil ? nil : $0 }
        )
    }

    // MARK: The break that is on

    /// What the break now on keeps blocked and the note it shows; nil for an
    /// ordinary break, which blocks nothing and says nothing.
    var breakRules: BreakRules? { engine?.breakState?.rules }

    /// The reminder for the break on, trimmed and bounded.
    var breakReminder: String? { breakRules?.displayReminder }

    /// "Social and x.com stay blocked until 10:40": the break's rules in a
    /// line, with when they end. nil when the break blocks nothing.
    func breakBlockedLine() -> String? {
        guard let rules = breakRules, let end = engine?.breakState?.endsAt else { return nil }
        let categories = self.categories
        return rules.stayBlockedLine(categories: categories,
                                     appName: { BreakRulesNames.app($0, categories: categories) },
                                     until: FocusFormat.clockTime(end))
    }

    /// The exceptions of the chosen categories, then the request's own, each
    /// once. Block mode only: the caller passes none for an allow list.
    func websiteExceptions(for categories: [FocusCategory], adding extra: [WebsiteException]) -> [WebsiteException] {
        SessionRequest.exceptions(of: categories, adding: extra)
    }
}
