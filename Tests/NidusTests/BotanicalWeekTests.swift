import Foundation
import Testing
@testable import Nidus

struct BotanicalWeekTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        return calendar
    }

    private func date(_ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func entry(ending end: Date, focused: TimeInterval = 1200, finished: Bool? = nil,
                       outcome: SessionEndReason = .completed) -> SessionEntry {
        SessionEntry(start: end.addingTimeInterval(-focused), end: end, focused: focused,
                     planned: nil, outcome: outcome, finished: finished)
    }

    @Test func firstRecordedSessionMakesOneMarkRegardlessOfGoalAnswerOrMoreSessions() {
        let now = date(4)
        let one = FocusBotanicalWeek(sessions: [entry(ending: now, finished: false)], now: now, calendar: calendar)
        let several = FocusBotanicalWeek(sessions: [entry(ending: now, finished: true), entry(ending: now)],
                                         now: now, calendar: calendar)
        #expect(one == several)
        #expect(one.days.count == 7)
        #expect(one.days.filter(\.hasSession).count == 1)
        #expect(one.days.last?.hasSession == true)
        #expect(!one.isEmpty)
    }

    @Test func markUsesCompletionDateAndIncludesManuallyEndedOpenEndedFocus() {
        let end = date(4, hour: 0, minute: 5)
        let overnight = entry(ending: end, focused: 1800, outcome: .endedEarly)
        let week = FocusBotanicalWeek(sessions: [overnight], now: date(4), calendar: calendar)
        #expect(week.days.last?.hasSession == true)
        #expect(week.days[5].hasSession == false)
    }

    @Test func windowHasSevenLocalDatesAcrossDaylightSavingAndKeepsStampShape() {
        let history = [entry(ending: date(1))]
        let before = FocusBotanicalWeek(sessions: history, now: date(4), calendar: calendar)
        let after = FocusBotanicalWeek(sessions: history, now: date(5), calendar: calendar)
        #expect(before.days.count == 7 && after.days.count == 7)
        #expect(Set(before.days.map(\.date)).count == 7)
        let stamp = before.days.first { $0.hasSession }
        #expect(stamp == after.days.first { $0.hasSession })
        #expect(before.days.allSatisfy { calendar.component(.hour, from: $0.date) == 0 })
    }

    @Test func oldFutureAndAccidentalShortSessionsDoNotCreateMarks() {
        let now = date(10)
        let week = FocusBotanicalWeek(sessions: [entry(ending: date(3)), entry(ending: date(11)),
                                                entry(ending: now, focused: 5)], now: now, calendar: calendar)
        #expect(week.isEmpty)
        #expect(week.days.count == 7)
        #expect(FocusBotanicalWeek(sessions: [], now: now, calendar: calendar).isEmpty)
    }

    @Test func changingTimeZoneAssignsTheMarkToTheCurrentLocalDay() {
        let end = date(4, hour: 1)
        var west = calendar
        west.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let week = FocusBotanicalWeek(sessions: [entry(ending: end)], now: date(4), calendar: west)
        #expect(week.days.last?.hasSession == false)
        #expect(week.days[5].hasSession == true)
    }
}
