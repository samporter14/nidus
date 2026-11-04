//
//  PresentationCaches.swift
//  Nidus
//
//  Small, replaceable results for views that share the session clock. The
//  clock may redraw a view; it should not recount unchanged history or
//  decode saved workspaces. No cache grows as new projects are visited.
//

import Foundation

struct HistorySummaryCache {
    private struct Context: Equatable {
        var version: Int
        var day: Date
        var calendar: Calendar
    }

    private var context: Context?
    private var cachedStats: FocusStats?
    private var cachedBotanicalWeek: FocusBotanicalWeek?
    private var cachedProject: (id: UUID, summary: ProjectSummary)?
    private var cachedRoster: ProjectSummary.Roster?

    mutating func stats(version: Int, now: Date = Date(), calendar: Calendar = .current,
                        sessions: @autoclosure () -> [SessionEntry]) -> FocusStats {
        updateContext(version: version, now: now, calendar: calendar)
        if let cachedStats { return cachedStats }
        let result = FocusStats(sessions: sessions(), now: now, calendar: calendar)
        cachedStats = result
        return result
    }

    mutating func botanicalWeek(version: Int, now: Date = Date(), calendar: Calendar = .current,
                                sessions: @autoclosure () -> [SessionEntry]) -> FocusBotanicalWeek {
        updateContext(version: version, now: now, calendar: calendar)
        if let cachedBotanicalWeek { return cachedBotanicalWeek }
        let result = FocusBotanicalWeek(sessions: sessions(), now: now, calendar: calendar)
        cachedBotanicalWeek = result
        return result
    }

    mutating func project(_ id: UUID, version: Int, now: Date = Date(), calendar: Calendar = .current,
                          sessions: @autoclosure () -> [SessionEntry]) -> ProjectSummary {
        updateContext(version: version, now: now, calendar: calendar)
        if let cachedProject, cachedProject.id == id { return cachedProject.summary }
        let result = ProjectSummary(projectID: id, sessions: sessions(), now: now, calendar: calendar)
        cachedProject = (id, result)
        return result
    }

    mutating func roster(version: Int, now: Date = Date(), calendar: Calendar = .current,
                         projects: @autoclosure () -> [FocusProject],
                         sessions: @autoclosure () -> [SessionEntry]) -> ProjectSummary.Roster {
        updateContext(version: version, now: now, calendar: calendar)
        if let cachedRoster { return cachedRoster }
        let result = ProjectSummary.roster(projects: projects(), sessions: sessions(), now: now, calendar: calendar)
        cachedRoster = result
        return result
    }

    /// Names, order and archive status are read from preferences. A project's
    /// own historical summary only depends on history, so it can stay.
    mutating func projectsDidChange() {
        cachedRoster = nil
    }

    private mutating func updateContext(version: Int, now: Date, calendar: Calendar) {
        let next = Context(version: version, day: calendar.startOfDay(for: now), calendar: calendar)
        guard next != context else { return }
        self = Self()
        context = next
    }
}

struct WidgetSetupCache {
    /// Only the four labels a widget can show; never its full workspaces.
    private var projection: [WidgetSnapshot.Setup]?

    mutating func value(setups: @autoclosure () -> [FocusSetup]) -> [WidgetSnapshot.Setup] {
        if let projection { return projection }
        let result = setups().prefix(WidgetSnapshot.setupLimit).map {
            WidgetSnapshot.Setup(id: $0.id.uuidString, name: $0.name, symbol: $0.symbol)
        }
        projection = result
        return result
    }

    mutating func invalidate() {
        projection = nil
    }
}
