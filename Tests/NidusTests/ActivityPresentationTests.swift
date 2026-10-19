import Foundation
import Testing
@testable import Nidus

struct ActivityPresentationTests {
    @Test func shortActivityDurationsKeepSecondPrecision() {
        #expect(ActivityDuration.string(37) == "37 sec")
        #expect(ActivityDuration.string(1) == "1 sec")
        #expect(ActivityDuration.string(0) == "0 sec")
        #expect(ActivityDuration.string(60) == "1 min")
    }

    @Test func projectInsightsRollUpOnlyAttributedSessionsInsideTheRange() {
        let firstProject = UUID()
        let secondProject = UUID()
        var first = entry([FocusActivity(appID: "editor", appName: "Editor", title: "Draft", seconds: 37)])
        first.projectID = firstProject
        first.projectName = "Manuscript"
        var second = entry([FocusActivity(appID: "editor", appName: "Editor", title: "Draft", seconds: 23)])
        second.projectID = firstProject
        second.projectName = "Manuscript"
        var other = entry([FocusActivity(appID: "browser", appName: "Browser", seconds: 90)])
        other.projectID = secondProject
        other.projectName = "Grant"
        var unassigned = entry([FocusActivity(appID: "notes", appName: "Notes", seconds: 120)])
        unassigned.projectID = nil
        var outside = entry([FocusActivity(appID: "editor", appName: "Editor", seconds: 300)])
        outside.projectID = firstProject
        outside.start = Date(timeIntervalSince1970: 2_000)

        let interval = DateInterval(start: Date(timeIntervalSince1970: 900), duration: 800)
        let summaries = ActivityProjectInsights.summaries(
            sessions: [first, second, other, unassigned, outside], interval: interval)

        #expect(summaries.count == 2)
        #expect(summaries.first?.projectID == secondProject)
        #expect(summaries.first?.observed == 90)
        #expect(summaries.first?.sessionCount == 1)
        let manuscript = summaries.first { $0.projectID == firstProject }
        #expect(manuscript?.name == "Manuscript")
        #expect(manuscript?.observed == 60)
        #expect(manuscript?.sessionCount == 2)
    }

    func entry(_ rows: [FocusActivity]?, foreground: [String: TimeInterval] = [:]) -> SessionEntry {
        SessionEntry(start: Date(timeIntervalSince1970: 1_000), end: Date(timeIntervalSince1970: 1_600),
                     focused: 600, planned: 600, outcome: .completed,
                     foreground: foreground, names: ["browser": "Browser"], activity: rows)
    }

    @Test func dimensionsAreNotAddedTogetherAndSameTitlesKeepTheirSource() {
        let rows = [
            FocusActivity(appID: "browser", appName: "Browser", site: "Google Docs", title: "Draft", seconds: 120),
            FocusActivity(appID: "word", appName: "Word", title: "Draft", seconds: 60),
            FocusActivity(appID: "browser", appName: "Browser", site: "Google Docs", title: "Draft", seconds: 30)
        ]
        let totals = ActivityTotals(sessions: [entry(rows)])
        #expect(totals.observed == 210)
        #expect(totals.focused == 600)
        #expect(totals.apps.reduce(0) { $0 + $1.seconds } == 210)
        #expect(totals.services.reduce(0) { $0 + $1.seconds } == 210)
        #expect(totals.sites.first?.seconds == 150)
        #expect(totals.documents.count == 2)
        #expect(totals.documents.map(\.id).count == Set(totals.documents.map(\.id)).count)
    }

    @Test func legacyFallbackDoesNotRestoreIntentionallyEmptyDetails() {
        let legacy = entry(nil, foreground: ["browser": 90])
        let empty = entry([], foreground: ["browser": 150])
        let totals = ActivityTotals(sessions: [legacy, empty])
        #expect(totals.observed == 90)
        #expect(totals.documents.isEmpty)
        #expect(totals.sites.isEmpty)
    }

    @Test func topServicesIncludeAllRemainingTimeExactlyOnce() {
        let rows = (1...8).map { FocusActivity(appID: "app\($0)", appName: "App \($0)", seconds: Double($0)) }
        let totals = ActivityTotals(sessions: [entry(rows)])
        #expect(totals.services.count == 5)
        #expect(totals.services.reduce(0) { $0 + $1.seconds } == 36)
        #expect(totals.services.last?.name == "Other")
    }

    @Test func periodsUseLocalCalendarAndExclusiveEndAcrossDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
        let interval = ActivityPeriod.today.interval(around: now, calendar: calendar)
        #expect(interval.duration == 25 * 3600)
        #expect(ActivityPeriod.today.contains(interval.start, now: now, calendar: calendar))
        #expect(!ActivityPeriod.today.contains(interval.end, now: now, calendar: calendar))
        #expect(ActivityPeriod.today.contains(interval.start.addingTimeInterval(-1), offset: -1, now: now, calendar: calendar))
    }
}
