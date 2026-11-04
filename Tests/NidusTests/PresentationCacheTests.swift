import Foundation
import Testing
@testable import Nidus

struct PresentationCacheTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))!
    }

    private func entry(project: UUID? = nil, finished: Bool? = nil) -> SessionEntry {
        SessionEntry(start: now.addingTimeInterval(-1800), end: now, focused: 1500,
                     planned: 1500, outcome: .completed, goal: "Write", finished: finished,
                     projectID: project, projectName: "Recorded name")
    }

    @Test func clockTicksReuseStatsAndHistoryEditsRefreshThem() {
        var cache = HistorySummaryCache()
        var history = [entry(finished: false)]
        var reads = 0
        func load() -> [SessionEntry] { reads += 1; return history }

        for tick in 0..<300 {
            let stats = cache.stats(version: 1, now: now.addingTimeInterval(Double(tick)),
                                    calendar: calendar, sessions: load())
            #expect(stats.sessionCount == 1 && stats.goalsFinished == 0)
        }
        #expect(reads == 1, "a session clock does not recount finished sessions")

        history[0].finished = true
        let answered = cache.stats(version: 2, now: now, calendar: calendar, sessions: load())
        #expect(answered.goalsFinished == 1)
        history = []
        let cleared = cache.stats(version: 3, now: now, calendar: calendar, sessions: load())
        #expect(cleared.isEmpty && reads == 3)
    }

    @Test func daysAndCalendarChangesRefreshStreaksAndGraphBoundaries() {
        var cache = HistorySummaryCache()
        var reads = 0
        func load() -> [SessionEntry] { reads += 1; return [entry()] }
        let initial = cache.stats(version: 1, now: now, calendar: calendar, sessions: load())
        #expect(initial.currentStreak == 1)

        let later = calendar.date(byAdding: .day, value: 2, to: now)!
        let afterGap = cache.stats(version: 1, now: later, calendar: calendar, sessions: load())
        #expect(afterGap.currentStreak == 0)
        #expect(reads == 2)

        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        let changedWeek = cache.stats(version: 1, now: later, calendar: sundayFirst, sessions: load())
        #expect(sundayFirst.component(.weekday, from: changedWeek.weeks[0][0].date) == 1)
        #expect(reads == 3, "a week-start edit invalidates even within the same local day")

        var otherZone = sundayFirst
        otherZone.timeZone = TimeZone(secondsFromGMT: -8 * 3600)!
        _ = cache.stats(version: 1, now: later, calendar: otherZone, sessions: load())
        #expect(reads == 4)
    }

    @Test func projectCacheKeepsOnlyTheCurrentProjectAndUsesItsCalendar() {
        var cache = HistorySummaryCache()
        let a = UUID(), b = UUID()
        var history = [entry(project: a, finished: false), entry(project: b)]
        var reads = 0
        func load() -> [SessionEntry] { reads += 1; return history }
        let first = cache.project(a, version: 1, now: now, calendar: calendar, sessions: load())
        #expect(first.sessionCount == 1 && first.unfinished.count == 1)
        _ = cache.project(a, version: 1, now: now, calendar: calendar, sessions: load())
        #expect(reads == 1)
        #expect(cache.project(b, version: 1, now: now, calendar: calendar, sessions: load()).projectID == b)
        _ = cache.project(a, version: 1, now: now, calendar: calendar, sessions: load())
        #expect(reads == 3, "visiting projects replaces one cached detail; it never grows a dictionary")

        history[0].finished = true
        let answered = cache.project(a, version: 2, now: now, calendar: calendar, sessions: load())
        #expect(answered.unfinished.isEmpty)
        let later = calendar.date(byAdding: .day, value: 2, to: now)!
        let afterGap = cache.project(a, version: 2, now: later, calendar: calendar, sessions: load())
        #expect(afterGap.stats.currentStreak == 0 && reads == 5)
    }

    @Test func rosterReadsPreferencesOnlyWhenHistoryCalendarOrProjectsChange() {
        var cache = HistorySummaryCache()
        var projects = [FocusProject(name: "First")]
        let history = [entry(project: projects[0].id)]
        var reads = 0
        func loadProjects() -> [FocusProject] { reads += 1; return projects }
        for _ in 0..<100 {
            let roster = cache.roster(version: 1, now: now, calendar: calendar,
                                      projects: loadProjects(), sessions: history)
            #expect(roster.live.first?.project.name == "First")
        }
        #expect(reads == 1)

        projects[0].name = "Renamed"
        projects[0].isArchived = true
        cache.projectsDidChange()
        let edited = cache.roster(version: 1, now: now, calendar: calendar,
                                  projects: loadProjects(), sessions: history)
        #expect(edited.live.first?.project.name == "Renamed")
        #expect(edited.live.first?.project.isArchived == true)

        projects = []
        cache.projectsDidChange()
        let deleted = cache.roster(version: 1, now: now, calendar: calendar,
                                   projects: loadProjects(), sessions: history)
        #expect(deleted.live.isEmpty && deleted.deleted.first?.recordedName == "Recorded name")
        #expect(reads == 3)

        let cleared = cache.roster(version: 2, now: now, calendar: calendar,
                                   projects: loadProjects(), sessions: [])
        #expect(cleared.live.isEmpty && cleared.deleted.isEmpty && reads == 4)
    }

    @Test func widgetTicksKeepOnlyFourLabelsAndSetupEditsRefreshThem() {
        var cache = WidgetSetupCache()
        var setups = (0..<12).map { FocusSetup(name: "Setup \($0)") }
        var reads = 0
        func load() -> [FocusSetup] { reads += 1; return setups }
        for _ in 0..<300 {
            let labels = cache.value(setups: load())
            #expect(labels.count == WidgetSnapshot.setupLimit)
            #expect(labels.first?.id == setups[0].id.uuidString)
        }
        #expect(reads == 1, "the widget tick never decodes workspaces again")

        setups.reverse()
        setups[0].name = "New first"
        setups[0].symbol = "pencil"
        cache.invalidate()
        let labels = cache.value(setups: load())
        #expect(labels.first?.name == "New first" && labels.first?.symbol == "pencil")
        #expect(labels.first?.id == setups[0].id.uuidString && reads == 2)
        setups = []
        cache.invalidate()
        #expect(cache.value(setups: load()).isEmpty)
        #expect(cache.value(setups: load()).isEmpty)
        #expect(reads == 3, "an empty setup list is a reusable result too")
    }

    @Test func botanicalWeekReusesItsSevenMarksUntilHistoryOrTheLocalDayChanges() {
        var cache = HistorySummaryCache()
        var history = [entry()]
        var reads = 0
        func load() -> [SessionEntry] { reads += 1; return history }
        for tick in 0..<300 {
            let week = cache.botanicalWeek(version: 1, now: now.addingTimeInterval(Double(tick)),
                                           calendar: calendar, sessions: load())
            #expect(week.days.count == 7)
            #expect(week.days.filter(\.hasSession).count == 1)
        }
        #expect(reads == 1)

        history = []
        let cleared = cache.botanicalWeek(version: 2, now: now, calendar: calendar, sessions: load())
        #expect(cleared.days.allSatisfy { !$0.hasSession } && reads == 2)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let rolled = cache.botanicalWeek(version: 2, now: tomorrow, calendar: calendar, sessions: load())
        #expect(rolled.days.last?.date == calendar.startOfDay(for: tomorrow))
        #expect(reads == 3)
    }
}
