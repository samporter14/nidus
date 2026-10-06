//
//  SettingsTabs.swift
//  Nidus
//
//  The tabs along the top of the Settings window, and which tab each page of
//  Settings belongs to. Pure, so the table can be tested: the window only
//  asks it where to go. Pages are named by id, as the rest of the app already
//  names them ("stats", "category:<id>", "setup:<id>", "schedule:<id>").
//

import Foundation

enum SettingsTab: String, CaseIterable, Sendable {
    case general, blocking, setups, schedules, stats, about

    /// The label under the toolbar icon, and the window's title while it is
    /// the one showing.
    var title: String {
        switch self {
        case .general: "General"
        case .blocking: "Blocking"
        case .setups: "Setups"
        case .schedules: "Schedules"
        case .stats: "Stats"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .blocking: "nosign"
        case .setups: "square.stack"
        case .schedules: "calendar.badge.clock"
        case .stats: "chart.bar.xaxis"
        case .about: "info.circle"
        }
    }

    /// The tabs a window has, in toolbar order: those whose page exists. A
    /// tab whose page isn't there yet (a feature not built) is left out, and
    /// comes in by itself once it is.
    static func available(hasPage: (SettingsTab) -> Bool) -> [SettingsTab] {
        allCases.filter(hasPage)
    }

    /// The tab to open on from what was saved: the one it names, or General
    /// when nothing was saved, it names no tab, or that tab isn't there.
    static func restored(from saved: String, available: [SettingsTab]) -> SettingsTab {
        SettingsTab(rawValue: saved).flatMap { available.contains($0) ? $0 : nil } ?? .general
    }

    /// The id that opens this tab at its own page. For Setups, Schedules and
    /// Stats it is the id their pages already had, from before the tabs.
    var pageID: String { rawValue }
}

/// Where a page of Settings opens: which tab, and whether it sits on top of
/// that tab's own page (so Back leads to it) or is that page itself.
struct SettingsRoute: Equatable, Sendable {
    let tab: SettingsTab
    let pushes: Bool

    /// `available` is the tabs the window has. A page for a tab that isn't
    /// there opens General instead: pushing it there would only say the page
    /// is gone.
    static func resolve(_ pageID: String, available: Set<SettingsTab> = Set(SettingsTab.allCases)) -> SettingsRoute {
        let route = route(for: pageID)
        return available.contains(route.tab) ? route : SettingsRoute(tab: .general, pushes: false)
    }

    private static func route(for pageID: String) -> SettingsRoute {
        // A tab's own id first: "setups" is the Setups tab, and "setup:<id>"
        // (checked below, with its colon) is one setup inside it.
        if let tab = SettingsTab(rawValue: pageID) { return SettingsRoute(tab: tab, pushes: false) }
        if pageID == NidusModel.launchAppsPageID { return SettingsRoute(tab: .general, pushes: true) }
        if pageID.hasPrefix(NidusModel.categoryPagePrefix) { return SettingsRoute(tab: .blocking, pushes: true) }
        if pageID.hasPrefix(NidusModel.setupPagePrefix) { return SettingsRoute(tab: .setups, pushes: true) }
        if pageID.hasPrefix(NidusModel.schedulePagePrefix) { return SettingsRoute(tab: .schedules, pushes: true) }
        return SettingsRoute(tab: .general, pushes: false)
    }
}

extension NidusModel.Key {
    /// The tab Settings was last left on.
    static let settingsTab = "settingsTab"
}
