import Foundation
import Testing
@testable import Nidus

@MainActor
@Suite struct ActivityFilterScopeTests {
    private let project = UUID()

    @Test func theRunningSessionFollowsTheProjectFilter() {
        #expect(ActivityFilterScope.includesLive(sessionProjectID: project, filter: project))
        #expect(!ActivityFilterScope.includesLive(sessionProjectID: UUID(), filter: project))
        #expect(ActivityFilterScope.includesLive(sessionProjectID: project, filter: nil))
        #expect(ActivityFilterScope.includesLive(sessionProjectID: nil, filter: nil))
        #expect(!ActivityFilterScope.includesLive(sessionProjectID: nil, filter: project))
    }

    @Test func chartsSayTheyIgnoreAnyActiveFilter() {
        #expect(ActivityFilterScope.chartsIgnoreFilters(projectID: project, focusOnly: false, category: nil))
        #expect(ActivityFilterScope.chartsIgnoreFilters(projectID: nil, focusOnly: true, category: nil))
        #expect(ActivityFilterScope.chartsIgnoreFilters(projectID: nil, focusOnly: false, category: "work"))
        #expect(!ActivityFilterScope.chartsIgnoreFilters(projectID: nil, focusOnly: false, category: nil))
    }

    @Test func aMatchingLiveSessionCountsInANarrowedScope() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 9))!
        let live = DateInterval(start: start, duration: 1800)
        var log = ActivityDayLog(day: "2026-11-04")
        log.add(FocusActivitySegment(start: start, end: start.addingTimeInterval(3600), appID: "id.Word", appName: "Word",
                                     site: nil, title: nil))
        let included = ActivityFilterScope.includesLive(sessionProjectID: project, filter: project) ? live : nil
        let excluded = ActivityFilterScope.includesLive(sessionProjectID: UUID(), filter: project) ? live : nil
        let with = ActivityScope(logs: [log], sessions: [], narrowed: true, live: included, calendar: calendar)
        let without = ActivityScope(logs: [log], sessions: [], narrowed: true, live: excluded, calendar: calendar)
        #expect(with.totals.observed == 1800)
        #expect(without.totals.observed == 0)
    }
}
