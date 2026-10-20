import Combine
import Foundation
import Testing
@testable import Nidus

@MainActor
struct ClockAndSummaryTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.locale = Locale(identifier: "en_US")
        return value
    }

    @Test func clockUpdatesDoNotInvalidateTheWholeModel() {
        let model = NidusModel()
        var clockChanges = 0
        var modelChanges = 0
        let clockSubscription = model.clock.objectWillChange.sink { clockChanges += 1 }
        let modelSubscription = model.objectWillChange.sink { modelChanges += 1 }
        let now = model.clock.now
        model.clock.advance(to: now.addingTimeInterval(1))
        model.clock.advance(to: now.addingTimeInterval(2))
        model.clock.advance(to: now.addingTimeInterval(2))
        #expect(clockChanges == 2)
        #expect(modelChanges == 0)
        #expect(model.clock.now == now.addingTimeInterval(2))
        withExtendedLifetime((clockSubscription, modelSubscription)) {}
    }

    @Test func historySummaryReusesTheDayAndRefreshesAfterHistoryChanges() {
        let cache = HistoryDayCache<Int>()
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12))!
        var builds = 0
        func value(_ version: Int, _ date: Date, _ zone: Calendar) -> Int {
            cache.value(historyVersion: version, now: date, calendar: zone) { _, _ in
                builds += 1
                return builds
            }
        }
        #expect(value(0, now, calendar) == 1)
        #expect(value(0, now.addingTimeInterval(1), calendar) == 1)
        #expect(value(1, now.addingTimeInterval(2), calendar) == 2,
                "Appending, deleting or answering a history entry changes its revision")
        #expect(value(1, now.addingTimeInterval(24 * 60 * 60), calendar) == 3,
                "Streaks and the graph advance on the next calendar day")
        var changedCalendar = calendar
        changedCalendar.firstWeekday = calendar.firstWeekday == 1 ? 2 : 1
        #expect(value(1, now.addingTimeInterval(24 * 60 * 60), changedCalendar) == 4,
                "Changing calendar layout rebuilds the graph even on the same day")
        changedCalendar.timeZone = TimeZone(secondsFromGMT: -4 * 60 * 60)!
        #expect(value(1, now.addingTimeInterval(24 * 60 * 60), changedCalendar) == 5)
        cache.invalidate()
        #expect(value(1, now.addingTimeInterval(24 * 60 * 60), changedCalendar) == 6)
    }

    @Test func dailyDetailsIncludeQuietDaysButExcludeFutureDays() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12))!
        let entry = SessionEntry(start: now, end: now.addingTimeInterval(1500), focused: 1500,
                                 planned: 1500, outcome: .completed)
        let stats = FocusStats(sessions: [entry], now: now, calendar: calendar, weeks: 2)
        let days = FocusDayDetails.days(in: stats)
        #expect(days.first?.date == calendar.startOfDay(for: now))
        #expect(days.first?.focused == 1500)
        #expect(days.contains { $0.focused == 0 })
        #expect(days.allSatisfy { !$0.isFuture && $0.date <= now })
        #expect(zip(days, days.dropFirst()).allSatisfy { pair in pair.0.date > pair.1.date })
    }

    @Test func cachedStatsFollowFinishedAnswersAndHistoryClearing() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = FocusController(directory: directory)
        let model = NidusModel()
        model.adoptForTesting(controller: controller)
        let now = Date()
        let entry = SessionEntry(start: now.addingTimeInterval(-1500), end: now, focused: 1500,
                                 planned: 1500, outcome: .completed, goal: "Draft")
        controller.history.append(entry)
        #expect(model.stats.sessionCount == 1)
        #expect(model.stats.goalsFinished == 0)
        controller.markFinished(entry.id, true)
        #expect(model.stats.goalsFinished == 1)
        controller.clearHistory()
        #expect(model.stats.isEmpty)
    }

    @Test func extendingAPausedSessionRefreshesItsPresentationImmediately() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let testClock = TestClock()
        let controller = FocusController(directory: directory, now: { testClock.now })
        let model = NidusModel()
        model.adoptForTesting(controller: controller)
        // The controller is not started: no system observers or blockers run.
        controller.engine.start(plan(25, apps: [], websites: []))
        controller.engine.pause()
        // Mirror the production engine -> controller -> model event delivery
        // without starting system observers or blockers.
        controller.engine.onEvent = { [weak model] event in model?.sessionDidChange(event) }
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        model.extendSession(by: 5 * 60)
        #expect(controller.engine.isPaused)
        #expect(model.remaining == 30 * 60)
        #expect(changes > 0, "The paused controls update without waiting for another timer tick")
        withExtendedLifetime(subscription) {}
    }

    @Test func dismissingAnAbsentBrickOfferDoesNotInvalidateTheModel() {
        let model = NidusModel()
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        model.dismissBrickOffer()
        model.dismissBrickOffer()
        #expect(changes == 0)
        withExtendedLifetime(subscription) {}
    }
}
