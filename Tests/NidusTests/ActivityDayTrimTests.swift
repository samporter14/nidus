import Foundation
import Testing
@testable import Nidus

struct ActivityDayTrimTests {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func segment(_ start: TimeInterval, _ end: TimeInterval, title: String? = nil,
                         continuity: Int = 1) -> FocusActivitySegment {
        FocusActivitySegment(start: base.addingTimeInterval(start), end: base.addingTimeInterval(end),
                             appID: "com.example.app", appName: "App", site: "example.com",
                             title: title, continuity: continuity)
    }

    @Test func trimsTheRecentTailAndItsMatchingTotals() {
        var log = ActivityDayLog(day: "2026-11-04")
        log.add(segment(0, 10, title: "Earlier"))
        log.add(segment(10, 20, title: "Last input"))
        log.add(segment(20, 30, title: "Idle"))

        let changed = log.trim(after: base.addingTimeInterval(15), continuityAtLeast: 1)
        #expect(changed)
        #expect(log.stretches.map(\.seconds) == [10, 5])
        #expect(log.totals.map(\.title) == ["Earlier", "Last input"])
        #expect(log.totals.map(\.seconds) == [10, 5])
        #expect(log.seconds == 15)
        let changedAgain = log.trim(after: base.addingTimeInterval(15), continuityAtLeast: 1)
        #expect(!changedAgain, "A correction is idempotent")
    }

    @Test func leavesEarlierContinuityUntouchedEvenAfterTheCutoff() {
        var log = ActivityDayLog(day: "2026-11-04")
        log.add(segment(100, 120, title: "Earlier launch", continuity: 0))
        log.add(segment(0, 20, title: "Current launch", continuity: 1))

        let changed = log.trim(after: base.addingTimeInterval(10), continuityAtLeast: 1)
        #expect(changed)
        #expect(log.stretches.map(\.seconds) == [20, 10])
        #expect(log.seconds == 30)
    }

    @Test func retractingEverythingLeavesAnEmptyDay() {
        var log = ActivityDayLog(day: "2026-11-04")
        log.add(segment(0, 10))
        let changed = log.trim(after: base, continuityAtLeast: 1)
        #expect(changed)
        #expect(log.isEmpty)
        let changedAgain = log.trim(after: base, continuityAtLeast: 1)
        #expect(!changedAgain)
    }

    @Test func foldedTitlesDebitTheirUnnamedTotalsRow() {
        var log = ActivityDayLog(day: "2026-11-04")
        for index in 0..<ActivityDayLog.totalsLimit {
            let at = TimeInterval(index * 2)
            log.add(segment(at, at + 1, title: "Title \(index)"))
        }
        let at = TimeInterval(ActivityDayLog.totalsLimit * 2)
        log.add(segment(at, at + 10, title: "Folded A"))
        log.add(segment(at + 10, at + 20, title: "Folded B"))

        let changed = log.trim(after: base.addingTimeInterval(at + 5), continuityAtLeast: 1)
        #expect(changed)
        #expect(log.totals.first { $0.title == nil }?.seconds == 5)
        #expect(log.seconds == TimeInterval(ActivityDayLog.totalsLimit) + 5)
        #expect(log.stretches.last?.title == "Folded A")
        #expect(log.stretches.last?.seconds == 5)
    }

    @Test func trimmingATruncatedTimelinePreservesDroppedHistory() {
        var log = ActivityDayLog(day: "2026-11-04")
        let count = ActivityDayLog.stretchLimit + 5
        for index in 0..<count {
            let at = TimeInterval(index * 2)
            log.add(segment(at, at + 1))
        }
        #expect(log.truncated)
        #expect(log.stretches.count == ActivityDayLog.stretchLimit)

        let cutoff = TimeInterval((count - 2) * 2) + 0.5
        let changedTail = log.trim(after: base.addingTimeInterval(cutoff), continuityAtLeast: 1)
        #expect(changedTail)
        #expect(log.seconds == TimeInterval(count) - 1.5)
        #expect(log.stretches.count == ActivityDayLog.stretchLimit - 1)
        #expect(log.stretches.last?.seconds == 0.5)

        let changedRest = log.trim(after: base, continuityAtLeast: 1)
        #expect(changedRest)
        #expect(log.stretches.isEmpty)
        #expect(log.seconds == 5, "The five dropped stretches have no evidence to retract")
        #expect(log.truncated)
    }
}
