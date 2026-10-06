//
//  CalendarTests.swift
//  NidusTests
//
//  "Until next meeting": which event counts, when the length is worked out,
//  and that nothing asks for Calendar access except a click. The calendar is
//  always a fake here; EventKit is never touched.
//

import Combine
import Foundation
import Testing
@testable import Nidus

private let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
}()

private func at(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: text) else { fatalError("bad date \(text)") }
    return date
}

private func event(_ title: String, _ start: String, _ end: String,
                   allDay: Bool = false, declined: Bool = false, cancelled: Bool = false) -> CalendarEvent {
    CalendarEvent(title: title, start: at(start), end: at(end), isAllDay: allDay, isDeclined: declined, isCancelled: cancelled)
}

struct NextMeetingTests {
    private let now = at("2026-03-10T13:20:00-04:00")

    private func next(_ events: [CalendarEvent]) -> Meeting? {
        Meeting.next(after: now, in: events, calendar: newYork)
    }

    @Test func theEarliestTimedEventToday() {
        let found = next([
            event("Planning", "2026-03-10T16:00:00-04:00", "2026-03-10T17:00:00-04:00"),
            event("Design review", "2026-03-10T14:00:00-04:00", "2026-03-10T15:00:00-04:00"),
        ])
        #expect(found == Meeting(title: "Design review", start: at("2026-03-10T14:00:00-04:00")))
    }

    @Test func allDayDeclinedAndCancelledEventsDoNotCount() {
        let found = next([
            event("Holiday", "2026-03-10T00:00:00-04:00", "2026-03-11T00:00:00-04:00", allDay: true),
            event("Birthday", "2026-03-10T14:00:00-04:00", "2026-03-10T14:30:00-04:00", allDay: true),
            event("Declined sync", "2026-03-10T14:00:00-04:00", "2026-03-10T14:30:00-04:00", declined: true),
            event("Cancelled sync", "2026-03-10T14:15:00-04:00", "2026-03-10T14:45:00-04:00", cancelled: true),
            event("Standup", "2026-03-10T15:30:00-04:00", "2026-03-10T15:45:00-04:00"),
        ])
        #expect(found?.title == "Standup")
    }

    @Test func anEventThatHasStartedIsNotNext() {
        #expect(next([event("Running long", "2026-03-10T13:00:00-04:00", "2026-03-10T14:00:00-04:00")]) == nil)
        // Starting this very second is not next either; there is nothing left to end before.
        #expect(next([event("Now", "2026-03-10T13:20:00-04:00", "2026-03-10T14:00:00-04:00")]) == nil)
    }

    @Test func onlyTodayCounts() {
        #expect(next([event("Late call", "2026-03-10T23:59:00-04:00", "2026-03-11T00:30:00-04:00")])?.title == "Late call")
        #expect(next([event("Tomorrow", "2026-03-11T00:00:00-04:00", "2026-03-11T01:00:00-04:00")]) == nil)
        #expect(next([event("Yesterday", "2026-03-09T15:00:00-04:00", "2026-03-09T16:00:00-04:00")]) == nil)
        #expect(next([]) == nil)
    }

    @Test func todayEndsAtMidnightOnTheDayOfAClockChange() {
        // Sunday March 8 is 23 hours long; its midnight is still the end of today.
        let sundayMorning = at("2026-03-08T09:00:00-04:00")
        let late = event("Late", "2026-03-08T23:30:00-04:00", "2026-03-09T00:30:00-04:00")
        let monday = event("Monday", "2026-03-09T00:00:00-04:00", "2026-03-09T01:00:00-04:00")
        #expect(Meeting.next(after: sundayMorning, in: [monday, late], calendar: newYork)?.title == "Late")
        #expect(Meeting.next(after: sundayMorning, in: [monday], calendar: newYork) == nil)
    }

    @Test func theMenuNamesTheTimeAndTheMeeting() {
        let meeting = Meeting(title: "Design review", start: at("2026-03-10T14:00:00-04:00"))
        // The time is in the Mac's zone and locale; the shape is what matters.
        #expect(meeting.menuTitle.hasPrefix("Until "))
        #expect(meeting.menuTitle.hasSuffix(" (Design review)"))
        let long = Meeting(title: "A very long meeting title that would run off the edge of the menu", start: meeting.start)
        #expect(long.menuTitle.hasSuffix("…)"))
        #expect(long.menuTitle.count < 60)
        #expect(Meeting(title: "  ", start: meeting.start).menuTitle.hasSuffix(")") == false)
    }
}

@MainActor
struct MeetingFinderTests {
    let source: FakeCalendarSource
    let finder: MeetingFinder
    /// Thirty seconds past 1:20, so 2:00 is 39 minutes and a half away.
    let now = at("2026-03-10T13:20:30-04:00")

    init() {
        source = FakeCalendarSource(access: .authorized, events: [
            event("Design review", "2026-03-10T14:00:00-04:00", "2026-03-10T15:00:00-04:00"),
        ])
        finder = MeetingFinder(source: source)
        finder.calendar = newYork
    }

    @Test func refreshFindsTheNextMeeting() {
        finder.refresh(now: now)
        #expect(finder.next?.title == "Design review")
        #expect(finder.offeredMinutes(now: now) == 39, "a partial minute is dropped, so the session ends before it")
    }

    @Test func refreshNeverAsksForAccess() {
        source.access = .notDetermined
        finder.refresh(now: now)
        #expect(finder.next == nil)
        #expect(finder.access == .notDetermined)
        #expect(source.requestCount == 0, "only a click asks")
    }

    @Test func aClickAsksOnceAndThenReads() async {
        source.access = .notDetermined
        let granted = await finder.requestAccess(now: now)
        #expect(granted)
        #expect(source.requestCount == 1)
        #expect(finder.next?.title == "Design review")
    }

    @Test func aRefusalLeavesNothingToOffer() async {
        source.access = .notDetermined
        source.grants = false
        let granted = await finder.requestAccess(now: now)
        #expect(!granted)
        #expect(finder.access == .unavailable)
        #expect(finder.next == nil)
        finder.refresh(now: now)
        #expect(finder.next == nil)
        #expect(source.requestCount == 1)
    }

    @Test func accessTakenBackInSettingsClearsTheMeeting() {
        finder.refresh(now: now)
        source.access = .unavailable
        finder.refresh(now: now)
        #expect(finder.next == nil)
    }

    @Test func aChangeIsAnnouncedOnce() {
        var changes = 0
        finder.didChange = { changes += 1 }
        finder.refresh(now: now)
        finder.refresh(now: now)
        #expect(changes == 1)
        source.events = []
        finder.refresh(now: now)
        #expect(changes == 2)
    }

    // MARK: The chosen length

    @Test func theLengthIsWorkedOutWhenTheSessionStartsNotWhenItWasChosen() {
        finder.refresh(now: now)
        finder.isChosen = true
        // The meeting moved later while the popover sat open.
        source.events = [event("Design review", "2026-03-10T15:00:00-04:00", "2026-03-10T16:00:00-04:00")]
        #expect(finder.minutesToChosenMeeting(now: at("2026-03-10T13:50:00-04:00")) == 70)
    }

    @Test func theChoiceIsSpentByASessionStart() {
        finder.isChosen = true
        #expect(finder.minutesToChosenMeeting(now: now) == 39)
        #expect(!finder.isChosen)
        #expect(finder.minutesToChosenMeeting(now: now) == nil, "the next session uses the popover's length again")
    }

    @Test func notChosenMeansThePopoversLength() {
        finder.refresh(now: now)
        #expect(finder.minutesToChosenMeeting(now: now) == nil)
    }

    @Test func aMeetingLessThanAMinuteAwayFallsBack() {
        finder.isChosen = true
        #expect(finder.minutesToChosenMeeting(now: at("2026-03-10T13:59:30-04:00")) == nil, "0 would mean open-ended")
        finder.isChosen = true
        #expect(finder.minutesToChosenMeeting(now: at("2026-03-10T13:59:00-04:00")) == 1)
    }

    @Test func aMeetingThatHasPassedFallsBack() {
        finder.isChosen = true
        #expect(finder.minutesToChosenMeeting(now: at("2026-03-10T14:30:00-04:00")) == nil)
    }

    @Test func pickingAFixedLengthTakesTheChoiceBack() {
        let changes = PassthroughSubject<String, Never>()
        finder.start(preferenceChanges: changes, didChange: {})
        finder.isChosen = true
        changes.send("snoozeMinutes")
        #expect(finder.isChosen)
        changes.send(NidusModel.Key.durationMinutes)
        #expect(!finder.isChosen)
        finder.stop()
        finder.isChosen = true
        changes.send(NidusModel.Key.durationMinutes)
        #expect(finder.isChosen, "stopped, it listens to nothing")
    }
}
