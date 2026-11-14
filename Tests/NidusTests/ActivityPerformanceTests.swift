import Foundation
import Testing
@testable import Nidus

/// The 0.6.7 speed-ups change how much is kept and read, never what is shown.
@MainActor
@Suite struct ActivityPerformanceTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        return calendar
    }
    private func at(day: Int, _ hour: Double) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day))!.addingTimeInterval(hour * 3600)
    }
    private func page(day: Int, _ from: Double, _ to: Double, site: String, title: String, path: String) -> FocusActivitySegment {
        FocusActivitySegment(start: at(day: day, from), end: at(day: day, to), appID: "id.S", appName: "Safari", site: site,
                             title: title, url: "https://\(site)/\(path)")
    }
    private func log(day: Int, _ stretches: [FocusActivitySegment]) -> ActivityDayLog {
        var log = ActivityDayLog(day: String(format: "2026-11-%02d", day))
        for stretch in stretches { log.add(stretch) }
        return log
    }
    private func session(day: Int, _ from: Double, _ to: Double, segments: [FocusActivitySegment]) -> SessionEntry {
        var entry = SessionEntry(start: at(day: day, from), end: at(day: day, to), focused: (to - from) * 3600, planned: nil,
                                 outcome: .completed, goal: "", blocks: [:], quits: [:], foreground: [:], names: [:])
        entry.activity = segments.map { FocusActivity(appID: $0.appID, appName: $0.appName, site: $0.site, title: $0.title,
                                                      seconds: $0.seconds) }
        entry.activitySegments = segments
        return entry
    }

    @Test func aMonthWithoutItsTimelineHasTheSameTotalsAddressesAndCategories() {
        // Logs out of day order, and a session with no daily record behind it
        // that comes after them, so the unsorted stretches aren't in time order.
        let logs = [
            log(day: 5, [page(day: 5, 9, 10, site: "nature.com", title: "C", path: "c"),
                         page(day: 5, 11, 12, site: "cell.com", title: "D", path: "d")]),
            log(day: 3, [page(day: 3, 9, 10, site: "nature.com", title: "A", path: "a"),
                         page(day: 3, 13, 14, site: "nature.com", title: "B", path: "b")]),
        ]
        let early = page(day: 1, 9, 10, site: "cell.com", title: "E", path: "e")
        let sessions = [session(day: 1, 9, 10, segments: [early])]
        let full = ActivityScope(logs: logs, sessions: sessions, calendar: calendar)
        let lean = ActivityScope(logs: logs, sessions: sessions, includeTimeline: false, calendar: calendar)
        #expect(lean.stretches.isEmpty)
        #expect(lean.hasStretches && full.hasStretches)
        #expect(full.stretches.count == 5)
        #expect(lean.totals.observed == full.totals.observed)
        #expect(lean.totals.sites.map(\.id) == full.totals.sites.map(\.id))
        #expect(lean.totals.sites.map(\.url) == full.totals.sites.map(\.url))
        #expect(lean.totals.sites.first { $0.id == "nature.com" }?.url == "https://nature.com/c")
        #expect(lean.totals.sites.first { $0.id == "cell.com" }?.url == "https://cell.com/d")
        #expect(lean.totals.documents.map(\.id) == full.totals.documents.map(\.id))
        #expect(lean.totals.documents.map(\.url) == full.totals.documents.map(\.url))
        let categorizer = ActivityCategorizer(categories: [], work: FocusCategory(id: "work", name: "Work", symbol: "briefcase",
                                                                                   apps: [], websites: ["nature.com"]),
                                              overrides: ActivityOverrides())
        #expect(lean.categoryTotals(using: categorizer) == full.categoryTotals(using: categorizer))
    }

    @Test func ofTwoAddressesAtTheSameMomentTheLaterInTheListIsKept() {
        let first = page(day: 3, 9, 10, site: "nature.com", title: "A", path: "a")
        let second = page(day: 3, 9, 10, site: "nature.com", title: "A", path: "b")
        var totals = ActivityTotals(rows: [(at(day: 3, 0), FocusActivity(appID: "id.S", appName: "Safari", site: "nature.com",
                                                                        title: "A", seconds: 3600))], focused: 0)
        totals.noteAddresses(from: [first, second])
        #expect(totals.sites.first?.url == "https://nature.com/b")
        totals.noteAddresses(from: [second, first])
        #expect(totals.sites.first?.url == "https://nature.com/a")
    }

    @Test func aDayStoreReadThatIsntCancelledReadsEveryDay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-perf-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityDayStore(directory: directory)
        for day in [3, 4, 5] {
            store.enqueue(.write(log(day: day, [page(day: day, 9, 10, site: "nature.com", title: "A", path: "a")])))
        }
        store.flush()
        let days = ["2026-11-05", "2026-11-03", "2026-11-04", "2026-11-06"]
        let read = await store.loadUnlessCancelled(days: days)
        #expect(read?.map(\.day) == (await store.load(days: days)).map(\.day))
        #expect(read?.map(\.day) == ["2026-11-03", "2026-11-04", "2026-11-05"])
    }

    @Test func aCancelledDayStoreReadStopsAndSaysSo() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-perf-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityDayStore(directory: directory)
        store.enqueue(.write(log(day: 3, [page(day: 3, 9, 10, site: "nature.com", title: "A", path: "a")])))
        store.flush()
        let task = Task { () -> [ActivityDayLog]? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.loadUnlessCancelled(days: ["2026-11-03"])
        }
        #expect(await task.value == nil)
    }
}
