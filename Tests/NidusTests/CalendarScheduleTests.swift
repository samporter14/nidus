//
//  CalendarScheduleTests.swift
//  NidusTests
//
//  Calendar-aware schedules: which events count, what a meeting in the way
//  offers (Shorten, Delay, Skip), that an unreadable calendar is unknown and
//  never "free", that a suggestion is checked again when it is acted on, and
//  that a shortened or delayed run starts once, through the same path as every
//  other. The calendar is always a fake, the clock is moved by hand, and the
//  zones are fixed (Los Angeles and New York, across their 2026 clock
//  changes). EventKit is never touched, and no session or card is made.
//

import Foundation
import Testing
@testable import Nidus

// MARK: - Helpers

private func zone(_ id: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: id)!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
}

private let losAngeles = zone("America/Los_Angeles")
private let newYork = zone("America/New_York")

/// "2026-03-09T09:00:00-07:00", read as the instant it names.
private func at(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: text) else { fatalError("bad date \(text)") }
    return date
}

private func meeting(_ start: String, _ end: String, title: String = "Standup",
                     allDay: Bool = false, declined: Bool = false, cancelled: Bool = false,
                     free: Bool = false) -> CalendarEvent {
    CalendarEvent(title: title, start: at(start), end: at(end), isAllDay: allDay,
                  isDeclined: declined, isCancelled: cancelled, isFree: free)
}

private func span(_ start: String, _ end: String) -> BusySpan {
    BusySpan(start: at(start), end: at(end))
}

/// Narrow no-break spaces before AM and PM, as macOS writes them.
private func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
}

private func schedule(_ id: String = "deep", _ start: (Int, Int) = (9, 0), _ end: (Int, Int) = (12, 0),
                      on: Bool = true, buffer: Int = 0) -> FocusSchedule {
    FocusSchedule(id: id, weekdays: FocusSchedule.everyDay,
                  start: ScheduleTime(hour: start.0, minute: start.1), end: ScheduleTime(hour: end.0, minute: end.1),
                  categoryIDs: ["social"], goal: "Deep work", checksCalendar: on, calendarBuffer: buffer)
}

// MARK: - The saved schedule

struct CalendarOptionStorageTests {
    @Test func aScheduleSavedBy03ReadsBackWithTheOptionOff() throws {
        // Exactly the keys 0.3 wrote: nothing about the calendar.
        let saved = Data(#"""
        [{"id":"a","isOn":true,"weekdays":[2,3,4,5,6],"start":{"hour":9,"minute":0},"end":{"hour":12,"minute":0},
          "categoryIDs":["social","messaging"],"mode":"block","strict":true,"goal":"Deep work"},
         {"id":"b","isOn":false,"weekdays":[1],"start":{"hour":13,"minute":30},"end":{"hour":15,"minute":0},
          "categoryIDs":["mail"],"mode":"allow","strict":false,"goal":""}]
        """#.utf8)
        let list = try #require(LossyJSON.list(FocusSchedule.self, from: saved))
        #expect(list.map(\.id) == ["a", "b"], "neither schedule is dropped")
        #expect(list.allSatisfy { !$0.checksCalendar && $0.calendarBuffer == 0 })
        #expect(list[0].goal == "Deep work" && list[0].strict && list[0].categoryIDs == ["social", "messaging"])
        #expect(!list[1].isOn && list[1].mode == .allow && list[1].weekdays == [1])
        // And the strict decoder, as the model's own reads would.
        #expect(try JSONDecoder().decode([FocusSchedule].self, from: saved).count == 2)
    }

    @Test func theOptionAndTheBufferRoundTrip() throws {
        let on = schedule(buffer: 10)
        let data = try JSONEncoder().encode([on])
        let back = try JSONDecoder().decode([FocusSchedule].self, from: data)
        #expect(back == [on])
        #expect(back[0].checksCalendar && back[0].calendarBuffer == 10)
    }

    @Test func aMalformedOptionLosesOnlyItself() throws {
        let saved = Data(#"""
        [{"id":"a","goal":"Keep me","checksCalendar":"yes please","calendarBuffer":"ten"},
         {"id":"b","checksCalendar":true,"calendarBuffer":7},
         {"id":"c","checksCalendar":true,"calendarBuffer":15}]
        """#.utf8)
        let list = try #require(LossyJSON.list(FocusSchedule.self, from: saved))
        #expect(list.count == 3)
        #expect(list[0].goal == "Keep me" && !list[0].checksCalendar && list[0].calendarBuffer == 0)
        #expect(list[1].checksCalendar && list[1].calendarBuffer == 0, "7 is not one of 0, 5, 10, 15")
        #expect(list[2].checksCalendar && list[2].calendarBuffer == 15)
    }

    @Test func theOptionIsOffByDefaultAndIsNotAMoveOfTheTiming() {
        #expect(!FocusSchedule().checksCalendar)
        #expect(FocusSchedule().calendarBuffer == 0)
        var edited = schedule(on: false)
        let base = edited
        edited.checksCalendar = true
        edited.calendarBuffer = 15
        #expect(!edited.changesTiming(from: base), "turning it on inside a window must not swallow a start")
        #expect(FocusSchedule.bufferChoices == [0, 5, 10, 15])
        #expect(FocusSchedule(calendarBuffer: 12).calendarBuffer == 0)
    }
}

// MARK: - Which events count

@MainActor
struct WhichEventsCountTests {
    @Test func timedAcceptedTentativeAndPlainEventsCount() {
        // Accepted, tentative, not yet answered, your own, and one with no one
        // else invited look the same here: none of them is declined.
        let events = [meeting("2026-03-09T10:00:00-07:00", "2026-03-09T11:00:00-07:00")]
        #expect(events.busySpans == [span("2026-03-09T10:00:00-07:00", "2026-03-09T11:00:00-07:00")])
    }

    @Test func declinedCancelledAllDayAndFreeEventsDoNot() {
        let events = [
            meeting("2026-03-09T10:00:00-07:00", "2026-03-09T11:00:00-07:00", declined: true),
            meeting("2026-03-09T10:00:00-07:00", "2026-03-09T11:00:00-07:00", cancelled: true),
            meeting("2026-03-09T00:00:00-07:00", "2026-03-10T00:00:00-07:00", allDay: true),
            meeting("2026-03-09T10:00:00-07:00", "2026-03-09T11:00:00-07:00", free: true),
        ]
        #expect(events.busySpans.isEmpty)
    }

    @Test func aSpanHasNoTitle() {
        let spans = [meeting("2026-03-09T10:00:00-07:00", "2026-03-09T11:00:00-07:00", title: "Patient review")].busySpans
        #expect(!String(describing: spans).contains("Patient"))
    }

    @Test func untilNextMeetingKeepsItsOwnOlderRule() {
        // A Free event still ends "Until next meeting", as it did in 0.3.
        let now = at("2026-03-09T08:00:00-07:00")
        let free = meeting("2026-03-09T10:00:00-07:00", "2026-03-09T11:00:00-07:00", title: "Hold", free: true)
        #expect(Meeting.next(after: now, in: [free], calendar: losAngeles)?.title == "Hold")
        #expect([free].busySpans.isEmpty, "the schedule check skips it")
    }

    @Test func aMissingCalendarIsUnknownAndAnEmptyOneIsNot() {
        let events = [meeting("2026-03-09T10:00:00-07:00", "2026-03-09T11:00:00-07:00")]
        let from = at("2026-03-09T09:00:00-07:00"), to = at("2026-03-09T12:00:00-07:00")
        #expect(FakeCalendarSource(access: .notDetermined, events: events).busySpans(from: from, to: to) == nil)
        #expect(FakeCalendarSource(access: .unavailable, events: events).busySpans(from: from, to: to) == nil)
        #expect(FakeCalendarSource(access: .authorized, events: []).busySpans(from: from, to: to) == [])
        #expect(FakeCalendarSource(access: .authorized, events: events).busySpans(from: from, to: to)?.count == 1)
    }

    @Test func aScheduleCheckDoesNotReadTitles() {
        let source = FakeCalendarSource(access: .authorized, events: [
            meeting("2026-03-09T10:00:00-07:00", "2026-03-09T11:00:00-07:00", title: "Secret")])
        let from = at("2026-03-09T09:00:00-07:00"), to = at("2026-03-09T12:00:00-07:00")
        #expect(source.events(from: from, to: to, includingTitles: false).map(\.title) == [""])
        #expect(source.events(from: from, to: to).map(\.title) == ["Secret"], "Until next meeting still shows its title")
    }
}

// MARK: - What a meeting in the way offers

struct ConflictMathTests {
    private let start = at("2026-03-09T09:00:00-07:00")
    private let end = at("2026-03-09T12:00:00-07:00")

    private func conflict(_ spans: [BusySpan], buffer: Int = 0, now: Date? = nil) -> ScheduleConflict? {
        FocusSchedule.conflict(start: start, end: end, spans: spans, buffer: buffer, now: now ?? start.addingTimeInterval(-60))
    }

    @Test func nothingInTheWayIsNoConflict() {
        #expect(conflict([]) == nil)
        #expect(conflict([span("2026-03-09T07:00:00-07:00", "2026-03-09T08:00:00-07:00")]) == nil, "before")
        #expect(conflict([span("2026-03-09T13:00:00-07:00", "2026-03-09T14:00:00-07:00")]) == nil, "after")
        #expect(conflict([span("2026-03-09T08:00:00-07:00", "2026-03-09T09:00:00-07:00")]) == nil, "ends as the block starts")
        #expect(conflict([span("2026-03-09T12:00:00-07:00", "2026-03-09T13:00:00-07:00")]) == nil, "starts as the block ends")
    }

    @Test func aMeetingInsideTheWindowOffersShortenAndDelay() throws {
        let found = try #require(conflict([span("2026-03-09T10:30:00-07:00", "2026-03-09T11:00:00-07:00")]))
        #expect(!found.startsDuring)
        #expect(found.shortenEnd == at("2026-03-09T10:30:00-07:00"))
        #expect(found.delayStart == at("2026-03-09T11:00:00-07:00"))
    }

    @Test func aMeetingOnAtTheStartOffersOnlyToStartLater() throws {
        let found = try #require(conflict([span("2026-03-09T08:30:00-07:00", "2026-03-09T09:30:00-07:00")]))
        #expect(found.startsDuring)
        #expect(found.shortenEnd == nil, "ending before it would end before starting")
        #expect(found.delayStart == at("2026-03-09T09:30:00-07:00"))
    }

    @Test func aMeetingThatRunsPastTheEndStillOffersToShorten() throws {
        let found = try #require(conflict([span("2026-03-09T11:00:00-07:00", "2026-03-09T13:00:00-07:00")]))
        #expect(found.shortenEnd == at("2026-03-09T11:00:00-07:00"))
        #expect(found.delayStart == nil, "it ends after the block does")
    }

    @Test func theBufferKeepsTheBlockAwayFromTheMeetingsStart() throws {
        let found = try #require(conflict([span("2026-03-09T10:30:00-07:00", "2026-03-09T11:00:00-07:00")], buffer: 10))
        #expect(found.shortenEnd == at("2026-03-09T10:20:00-07:00"))
        #expect(found.delayStart == at("2026-03-09T11:10:00-07:00"), "and the same gap after it")
        // A meeting just past the end is in the way once the gap would reach it.
        let near = span("2026-03-09T12:05:00-07:00", "2026-03-09T13:00:00-07:00")
        #expect(conflict([near], buffer: 0) == nil)
        #expect(conflict([near], buffer: 5) == nil, "5 minutes ahead of 12:05 is 12:00, which is not before the end")
        let reached = try #require(conflict([near], buffer: 10))
        #expect(reached.shortenEnd == at("2026-03-09T11:55:00-07:00"))
    }

    @Test func everyBufferChoiceMovesBothOffers() throws {
        for buffer in FocusSchedule.bufferChoices {
            let found = try #require(conflict([span("2026-03-09T10:30:00-07:00", "2026-03-09T11:00:00-07:00")], buffer: buffer))
            #expect(found.shortenEnd == at("2026-03-09T10:30:00-07:00").addingTimeInterval(-TimeInterval(buffer * 60)))
            #expect(found.delayStart == at("2026-03-09T11:00:00-07:00").addingTimeInterval(TimeInterval(buffer * 60)))
        }
    }

    @Test func anOptionThatLeavesUnderTenMinutesIsNotOffered() throws {
        // Ends at 9:05: shortening leaves 5 minutes. Starts later, so it is delayed.
        let early = try #require(conflict([span("2026-03-09T09:05:00-07:00", "2026-03-09T10:00:00-07:00")]))
        #expect(early.shortenEnd == nil)
        #expect(early.delayStart == at("2026-03-09T10:00:00-07:00"))
        // Exactly ten minutes is enough.
        let ten = try #require(conflict([span("2026-03-09T09:10:00-07:00", "2026-03-09T10:00:00-07:00")]))
        #expect(ten.shortenEnd == at("2026-03-09T09:10:00-07:00"))
        // The meeting ends at 11:55: delaying leaves 5.
        let late = try #require(conflict([span("2026-03-09T10:00:00-07:00", "2026-03-09T11:55:00-07:00")]))
        #expect(late.delayStart == nil)
        #expect(late.shortenEnd == at("2026-03-09T10:00:00-07:00"))
        let justEnough = try #require(conflict([span("2026-03-09T10:00:00-07:00", "2026-03-09T11:50:00-07:00")]))
        #expect(justEnough.delayStart == at("2026-03-09T11:50:00-07:00"))
        // A meeting that fills it leaves nothing to offer but Skip.
        let all = try #require(conflict([span("2026-03-09T09:05:00-07:00", "2026-03-09T11:55:00-07:00")]))
        #expect(all.shortenEnd == nil && all.delayStart == nil)
    }

    @Test func aBlockUnderWayIsMeasuredFromNow() throws {
        // Late by 25 minutes: a meeting at 9:30 leaves five minutes, not 30.
        let found = try #require(conflict([span("2026-03-09T09:30:00-07:00", "2026-03-09T10:00:00-07:00")],
                                          now: at("2026-03-09T09:25:00-07:00")))
        #expect(found.shortenEnd == nil)
        #expect(found.delayStart == at("2026-03-09T10:00:00-07:00"))
    }

    @Test func overlappingEventsAreOneBusySpan() throws {
        let found = try #require(conflict([
            span("2026-03-09T10:30:00-07:00", "2026-03-09T11:00:00-07:00"),
            span("2026-03-09T10:45:00-07:00", "2026-03-09T11:30:00-07:00"),
            span("2026-03-09T10:35:00-07:00", "2026-03-09T10:40:00-07:00"),
        ]))
        #expect(found.span == span("2026-03-09T10:30:00-07:00", "2026-03-09T11:30:00-07:00"))
        #expect(found.shortenEnd == at("2026-03-09T10:30:00-07:00"))
        #expect(found.delayStart == at("2026-03-09T11:30:00-07:00"), "not 11:00, which is inside the second")
    }

    @Test func backToBackEventsAreOneSpan() {
        let merged = FocusSchedule.merged([
            span("2026-03-09T11:00:00-07:00", "2026-03-09T11:30:00-07:00"),
            span("2026-03-09T10:30:00-07:00", "2026-03-09T11:00:00-07:00"),
        ], buffer: 0)
        #expect(merged == [span("2026-03-09T10:30:00-07:00", "2026-03-09T11:30:00-07:00")])
        // A real gap keeps them apart.
        #expect(FocusSchedule.merged([
            span("2026-03-09T10:30:00-07:00", "2026-03-09T11:00:00-07:00"),
            span("2026-03-09T11:10:00-07:00", "2026-03-09T11:30:00-07:00"),
        ], buffer: 5).count == 2)
    }

    @Test func eventsCloserThanTheBufferAreOneSpan() throws {
        // Delaying to 11:00 + 5 would land inside the second meeting.
        let found = try #require(conflict([
            span("2026-03-09T10:30:00-07:00", "2026-03-09T11:00:00-07:00"),
            span("2026-03-09T11:03:00-07:00", "2026-03-09T11:30:00-07:00"),
        ], buffer: 5))
        #expect(found.span == span("2026-03-09T10:30:00-07:00", "2026-03-09T11:30:00-07:00"))
        #expect(found.delayStart == at("2026-03-09T11:35:00-07:00"))
    }

    @Test func aSpanThatEndsBeforeItStartsIsIgnored() {
        #expect(FocusSchedule.merged([span("2026-03-09T11:00:00-07:00", "2026-03-09T10:00:00-07:00"),
                                      span("2026-03-09T10:00:00-07:00", "2026-03-09T10:00:00-07:00")], buffer: 0).isEmpty)
    }

    @Test func theFirstMeetingInTheWayIsTheOneOffered() throws {
        let found = try #require(conflict([
            span("2026-03-09T11:00:00-07:00", "2026-03-09T11:30:00-07:00"),
            span("2026-03-09T10:00:00-07:00", "2026-03-09T10:15:00-07:00"),
        ]))
        #expect(found.span.start == at("2026-03-09T10:00:00-07:00"))
        #expect(found.delayStart == at("2026-03-09T10:15:00-07:00"), "a later one is dealt with at the next card")
    }

    // MARK: Midnight, clock changes

    @Test func aMeetingAcrossMidnightCannotDelayAWindowThatEndsBeforeItEnds() throws {
        let found = FocusSchedule.conflict(
            start: at("2026-03-09T23:00:00-07:00"), end: at("2026-03-09T23:59:00-07:00"),
            spans: [span("2026-03-09T23:30:00-07:00", "2026-03-10T00:30:00-07:00")], buffer: 0,
            now: at("2026-03-09T22:59:00-07:00"))
        let offers = try #require(found)
        #expect(offers.shortenEnd == at("2026-03-09T23:30:00-07:00"))
        #expect(offers.delayStart == nil)
    }

    @Test func aMeetingFromYesterdayIsOnAtMidnight() throws {
        let found = try #require(FocusSchedule.conflict(
            start: at("2026-03-10T00:00:00-07:00"), end: at("2026-03-10T02:00:00-07:00"),
            spans: [span("2026-03-09T23:00:00-07:00", "2026-03-10T00:45:00-07:00")], buffer: 5,
            now: at("2026-03-09T23:59:00-07:00")))
        #expect(found.startsDuring)
        #expect(found.delayStart == at("2026-03-10T00:50:00-07:00"))
    }

    @Test func offersAreRealTimeAcrossTheSpringForward() throws {
        // Sunday March 8, Los Angeles: 2:00 AM becomes 3:00. 1:00 to 5:00 on the
        // wall clock is three real hours; a meeting at 3:30 is 90 minutes in.
        let found = try #require(FocusSchedule.conflict(
            start: at("2026-03-08T01:00:00-08:00"), end: at("2026-03-08T05:00:00-07:00"),
            spans: [span("2026-03-08T03:30:00-07:00", "2026-03-08T04:00:00-07:00")], buffer: 0,
            now: at("2026-03-08T00:59:00-08:00")))
        #expect(found.shortenEnd == at("2026-03-08T03:30:00-07:00"))
        #expect(found.shortenEnd?.timeIntervalSince(at("2026-03-08T01:00:00-08:00")) == TimeInterval(90 * 60))
        #expect(found.delayStart == at("2026-03-08T04:00:00-07:00"))
        // A meeting that starts at 3:55 after a 1:00 start leaves under ten real
        // minutes of the hour that the wall clock calls 55: not offered.
        let tight = try #require(FocusSchedule.conflict(
            start: at("2026-03-08T01:55:00-08:00"), end: at("2026-03-08T05:00:00-07:00"),
            spans: [span("2026-03-08T03:00:00-07:00", "2026-03-08T04:00:00-07:00")], buffer: 0,
            now: at("2026-03-08T01:54:00-08:00")))
        #expect(tight.shortenEnd == nil, "3:00 PDT is five minutes after 1:55 PST")
    }

    @Test func offersAreRealTimeAcrossTheFallBack() throws {
        // Sunday November 1: 2:00 AM becomes 1:00. 12:30 AM to 3:00 AM is three
        // and a half real hours. A meeting at the second 1:15 is 105 minutes in.
        let found = try #require(FocusSchedule.conflict(
            start: at("2026-11-01T00:30:00-07:00"), end: at("2026-11-01T03:00:00-08:00"),
            spans: [span("2026-11-01T01:15:00-08:00", "2026-11-01T02:00:00-08:00")], buffer: 0,
            now: at("2026-11-01T00:29:00-07:00")))
        #expect(found.shortenEnd?.timeIntervalSince(at("2026-11-01T00:30:00-07:00")) == TimeInterval(105 * 60))
        #expect(found.delayStart == at("2026-11-01T02:00:00-08:00"))
    }
}

// MARK: - Saying it

struct ConflictWordingTests {
    @Test func theCardNamesTheTimeAndNeverTheMeeting() throws {
        let events = [meeting("2026-03-09T10:30:00-07:00", "2026-03-09T11:00:00-07:00", title: "Tumor board")]
        let found = try #require(FocusSchedule.conflict(
            start: at("2026-03-09T09:00:00-07:00"), end: at("2026-03-09T12:00:00-07:00"),
            spans: events.busySpans, buffer: 0, now: at("2026-03-09T08:59:00-07:00")))
        let line = plain(found.line(calendar: losAngeles))
        #expect(line == "Meeting at 10:30 AM \u{2014} your block runs into it")
        #expect(!line.contains("Tumor"))
    }

    @Test func theSameInstantIsSaidInTheZoneItIsAskedIn() throws {
        let found = ScheduleConflict(span: span("2026-03-09T10:30:00-07:00", "2026-03-09T11:00:00-07:00"),
                                     startsDuring: false, shortenEnd: nil, delayStart: nil)
        #expect(plain(found.line(calendar: losAngeles)).hasPrefix("Meeting at 10:30 AM"))
        #expect(plain(found.line(calendar: newYork)).hasPrefix("Meeting at 1:30 PM"))
    }

    @Test func aMeetingAlreadyOnSaysUntilWhen() {
        let found = ScheduleConflict(span: span("2026-03-09T08:30:00-07:00", "2026-03-09T09:30:00-07:00"),
                                     startsDuring: true, shortenEnd: nil, delayStart: at("2026-03-09T09:30:00-07:00"))
        #expect(plain(found.line(calendar: losAngeles)) == "In a meeting until 9:30 AM \u{2014} your block starts during it")
        #expect(plain(found.delayDetail(calendar: losAngeles) ?? "") == "Start at 9:30 AM")
        #expect(found.shortenDetail(calendar: losAngeles) == nil)
    }
}

// MARK: - Running them

/// A calendar that counts how often it is read, so "no polling" is a number.
@MainActor
final class CountingCalendarSource: CalendarSource {
    let inner: FakeCalendarSource
    private(set) var reads = 0

    init(access: CalendarAccess = .authorized, events: [CalendarEvent] = []) {
        inner = FakeCalendarSource(access: access, events: events)
    }

    var access: CalendarAccess { inner.access }
    func requestAccess() async -> Bool { await inner.requestAccess() }
    func events(from start: Date, to end: Date, includingTitles: Bool) -> [CalendarEvent] {
        reads += 1
        return inner.events(from: start, to: end, includingTitles: includingTitles)
    }
}

@MainActor
final class CalendarHost: ScheduleHost {
    var schedules: [FocusSchedule] = []
    var scheduleHandled: [String: Date] = [:]
    var isSessionOrBreakOn = false
    struct Start { var id: String; var goal: String; var start: Date; var end: Date; var minutes: Int; var missed: Bool }
    var started: [Start] = []
    var cards: [(run: FocusSchedule.Occurrence, conflict: ScheduleConflict?)] = []
    var dismissals = 0
    var logs: [String] = []

    func startScheduled(_ occurrence: FocusSchedule.Occurrence, minutes: Int, asksBrowserAccess: Bool, missed: Bool) -> Bool {
        started.append(Start(id: occurrence.schedule.id, goal: occurrence.schedule.goal, start: occurrence.start,
                             end: occurrence.end, minutes: minutes, missed: missed))
        isSessionOrBreakOn = true
        return true
    }
    func presentHeadsUp(for occurrence: FocusSchedule.Occurrence) { cards.append((occurrence, nil)) }
    func presentHeadsUp(for occurrence: FocusSchedule.Occurrence, conflict: ScheduleConflict?) {
        cards.append((occurrence, conflict))
    }
    func dismissHeadsUp() { dismissals += 1 }
    func logSchedule(_ message: String) { logs.append(message) }
}

/// A scheduler on a fake host, a fake calendar and a clock moved by hand.
@MainActor
struct Rig {
    let host = CalendarHost()
    let clock = TestClock()
    let source: CountingCalendarSource
    let scheduler: FocusScheduler

    init(_ schedules: [FocusSchedule]? = nil, events: [CalendarEvent] = [],
         access: CalendarAccess = .authorized, calendar: Calendar = losAngeles) {
        source = CountingCalendarSource(access: access, events: events)
        let clock = clock
        scheduler = FocusScheduler(host: host, now: { clock.now }, calendar: { calendar })
        let source = source
        scheduler.calendarSource = { source }
        host.schedules = schedules ?? [schedule()]
        clock.now = at("2026-03-09T08:00:00-07:00")
    }

    /// Looks at the schedules at `text`.
    @discardableResult
    func go(_ text: String, _ reason: FocusScheduler.Reason = .timer) -> Date? {
        clock.now = at(text)
        return scheduler.evaluate(reason)
    }

    /// Moves the clock without looking.
    func sayAt(_ text: String) { clock.now = at(text) }
}

@MainActor
struct CalendarSchedulerTests {
    private let tenThirty = meeting("2026-03-09T10:30:00-07:00", "2026-03-09T11:00:00-07:00")

    // MARK: Off, unknown, and nothing in the way

    @Test func withTheOptionOffTheCalendarIsNeverReadAndNothingChanges() throws {
        let s = Rig([schedule(on: false)], events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        #expect(s.host.cards.count == 1 && s.host.cards[0].conflict == nil, "the plain card")
        s.go("2026-03-09T09:00:01-07:00")
        let first = try #require(s.host.started.first)
        #expect(first.minutes == 180 && !first.missed, "the whole window, as before")
        #expect(s.source.reads == 0)
        #expect(s.scheduler.adjustments.isEmpty)
        #expect(s.host.logs.allSatisfy { !$0.lowercased().contains("calendar") })
    }

    @Test func aCalendarThatCannotBeReadIsUnknownAndTheScheduleRunsAsSet() throws {
        for access in [CalendarAccess.notDetermined, .unavailable] {
            let s = Rig(events: [tenThirty], access: access)
            s.go("2026-03-09T08:59:00-07:00")
            #expect(s.host.cards.count == 1)
            #expect(s.host.cards[0].conflict == nil, "unknown is not a conflict, and not 'no meetings' either")
            #expect(s.host.logs.contains { $0.contains("couldn't be checked") })
            s.go("2026-03-09T09:00:01-07:00")
            #expect(s.host.started.map(\.minutes) == [180])
            #expect(s.source.inner.requestCount == 0, "only the button asks for access")
        }
    }

    @Test func accessTakenBackBetweenTheCardAndTheClickWithdrawsTheChoice() {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        #expect(s.host.cards[0].conflict != nil)
        s.source.inner.access = .unavailable
        s.sayAt("2026-03-09T08:59:30-07:00")
        s.scheduler.shorten(s.host.cards[0].run)
        #expect(s.scheduler.adjustments.isEmpty)
        #expect(s.host.logs.contains { $0.contains("couldn't be checked") })
        s.go("2026-03-09T09:00:01-07:00")
        #expect(s.host.started.map(\.minutes) == [180])
    }

    @Test func nothingInTheWayShowsThePlainCard() {
        let s = Rig(events: [meeting("2026-03-09T13:00:00-07:00", "2026-03-09T14:00:00-07:00")])
        s.go("2026-03-09T08:59:00-07:00")
        #expect(s.host.cards.count == 1 && s.host.cards[0].conflict == nil)
        #expect(s.source.reads == 1)
    }

    @Test func declinedCancelledAllDayAndFreeEventsAreNotInTheWay() {
        let s = Rig(events: [
            meeting("2026-03-09T10:30:00-07:00", "2026-03-09T11:00:00-07:00", declined: true),
            meeting("2026-03-09T10:30:00-07:00", "2026-03-09T11:00:00-07:00", cancelled: true),
            meeting("2026-03-09T00:00:00-07:00", "2026-03-10T00:00:00-07:00", allDay: true),
            meeting("2026-03-09T10:30:00-07:00", "2026-03-09T11:00:00-07:00", free: true),
        ])
        s.go("2026-03-09T08:59:00-07:00")
        #expect(s.host.cards[0].conflict == nil)
    }

    // MARK: The card

    @Test func aMeetingInTheWayShowsTheOffersAndNoTitle() throws {
        let s = Rig(events: [meeting("2026-03-09T10:30:00-07:00", "2026-03-09T11:00:00-07:00", title: "Oncology secret")])
        s.go("2026-03-09T08:59:00-07:00")
        let conflict = try #require(s.host.cards.first?.conflict)
        #expect(conflict.shortenEnd == at("2026-03-09T10:30:00-07:00"))
        #expect(conflict.delayStart == at("2026-03-09T11:00:00-07:00"))
        #expect(!String(describing: conflict).contains("secret"))
        // Nothing the scheduler says, in any log, has a title in it.
        s.scheduler.shorten(s.host.cards[0].run)
        s.go("2026-03-09T09:00:01-07:00")
        #expect(s.host.logs.allSatisfy { !$0.lowercased().contains("oncology") && !$0.lowercased().contains("secret") })
    }

    @Test func aMeetingOnAtTheStartOffersOnlyDelay() throws {
        let s = Rig(events: [meeting("2026-03-09T08:30:00-07:00", "2026-03-09T09:30:00-07:00")])
        s.go("2026-03-09T08:59:00-07:00")
        let conflict = try #require(s.host.cards.first?.conflict)
        #expect(conflict.startsDuring && conflict.shortenEnd == nil)
        #expect(conflict.delayStart == at("2026-03-09T09:30:00-07:00"))
    }

    @Test func aBufferMovesWhatTheCardOffers() throws {
        let s = Rig([schedule(buffer: 10)], events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        let conflict = try #require(s.host.cards.first?.conflict)
        #expect(conflict.shortenEnd == at("2026-03-09T10:20:00-07:00"))
        #expect(conflict.delayStart == at("2026-03-09T11:10:00-07:00"))
    }

    @Test func overlappingEventsMakeOneOffer() throws {
        let s = Rig(events: [tenThirty, meeting("2026-03-09T10:45:00-07:00", "2026-03-09T11:30:00-07:00")])
        s.go("2026-03-09T08:59:00-07:00")
        #expect(s.host.cards.first?.conflict?.delayStart == at("2026-03-09T11:30:00-07:00"))
    }

    @Test func leavingItAloneStartsTheBlockAsScheduled() throws {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.go("2026-03-09T09:00:01-07:00")
        let first = try #require(s.host.started.first)
        #expect(first.minutes == 180 && first.end == at("2026-03-09T12:00:00-07:00"), "a card nobody answers changes nothing")
    }

    @Test func noOptionsLeftMeansOnlySkip() throws {
        let s = Rig(events: [meeting("2026-03-09T09:05:00-07:00", "2026-03-09T11:55:00-07:00")])
        s.go("2026-03-09T08:59:00-07:00")
        let conflict = try #require(s.host.cards.first?.conflict)
        #expect(conflict.shortenEnd == nil && conflict.delayStart == nil)
        s.scheduler.skip(s.host.cards[0].run)
        s.go("2026-03-09T09:00:01-07:00")
        #expect(s.host.started.isEmpty)
    }

    // MARK: Shorten

    @Test func shortenEndsTheBlockWhereTheMeetingBegins() throws {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.sayAt("2026-03-09T08:59:30-07:00")
        s.scheduler.shorten(s.host.cards[0].run)
        #expect(s.scheduler.adjustments["deep"]?.run.end == at("2026-03-09T10:30:00-07:00"))
        #expect(s.host.started.isEmpty, "nothing starts until the start time")
        // A moment after 9:00, as a timer is.
        s.go("2026-03-09T09:00:01.5-07:00")
        let first = try #require(s.host.started.first)
        #expect(first.end == at("2026-03-09T10:30:00-07:00"))
        #expect(first.minutes == 89, "no slack: it ends before 10:30, not a few seconds into it")
        #expect(s.scheduler.adjustments.isEmpty, "used once")
    }

    @Test func shortenOnTimeEndsExactlyAtTheMeeting() throws {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.scheduler.shorten(s.host.cards[0].run)
        s.go("2026-03-09T09:00:00-07:00")
        #expect(s.host.started.map(\.minutes) == [90])
    }

    @Test func shortenWithABufferEndsEarlier() throws {
        let s = Rig([schedule(buffer: 15)], events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.scheduler.shorten(s.host.cards[0].run)
        s.go("2026-03-09T09:00:00-07:00")
        #expect(s.host.started.map(\.minutes) == [75])
        #expect(s.host.started.first?.end == at("2026-03-09T10:15:00-07:00"))
    }

    // MARK: Delay

    @Test func delayStartsTheBlockWhenTheMeetingEndsAndKeepsTheEnd() throws {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.sayAt("2026-03-09T08:59:30-07:00")
        s.scheduler.delay(s.host.cards[0].run)
        #expect(s.scheduler.adjustments["deep"]?.run.start == at("2026-03-09T11:00:00-07:00"))
        #expect(s.scheduler.adjustments["deep"]?.run.end == at("2026-03-09T12:00:00-07:00"))
        #expect(s.host.scheduleHandled["deep"] == at("2026-03-09T09:00:00-07:00"), "the 9:00 run is dealt with")
        // 9:00 passes with nothing started.
        let wake = s.go("2026-03-09T09:00:01-07:00")
        #expect(s.host.started.isEmpty)
        #expect(wake == at("2026-03-09T10:59:00-07:00"), "the next look is the delayed run's heads-up")
        // Its own heads-up, then its start.
        s.go("2026-03-09T10:59:00-07:00")
        #expect(s.host.cards.count == 2 && s.host.cards[1].run.start == at("2026-03-09T11:00:00-07:00"))
        s.go("2026-03-09T11:00:01-07:00")
        let first = try #require(s.host.started.first)
        #expect(first.start == at("2026-03-09T11:00:00-07:00") && first.end == at("2026-03-09T12:00:00-07:00"))
        #expect(first.minutes == 60 && !first.missed)
    }

    @Test func delayAfterAMeetingAlreadyOnStartsWhenItEnds() throws {
        let s = Rig(events: [meeting("2026-03-09T08:30:00-07:00", "2026-03-09T09:30:00-07:00")])
        s.go("2026-03-09T08:59:00-07:00")
        s.scheduler.delay(s.host.cards[0].run)
        s.go("2026-03-09T09:00:01-07:00")
        #expect(s.host.started.isEmpty)
        s.go("2026-03-09T09:30:00-07:00")
        #expect(s.host.started.map(\.minutes) == [150])
    }

    @Test func delayWithABufferWaitsForTheGapToo() throws {
        let s = Rig([schedule(buffer: 5)], events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.scheduler.delay(s.host.cards[0].run)
        #expect(s.scheduler.adjustments["deep"]?.run.start == at("2026-03-09T11:05:00-07:00"))
    }

    @Test func aSkippedDelayedRunDoesNotStart() {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.scheduler.delay(s.host.cards[0].run)
        s.go("2026-03-09T10:59:00-07:00")
        s.scheduler.skip(s.host.cards[1].run)
        s.go("2026-03-09T11:00:01-07:00")
        #expect(s.host.started.isEmpty)
        #expect(s.scheduler.adjustments.isEmpty)
    }

    @Test func aDelayedRunCanBeStartedEarlyFromItsOwnCard() throws {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.scheduler.delay(s.host.cards[0].run)
        s.go("2026-03-09T10:59:00-07:00")
        s.sayAt("2026-03-09T10:59:20-07:00")
        s.scheduler.startNow(s.host.cards[1].run)
        #expect(s.host.started.count == 1)
        s.host.isSessionOrBreakOn = false
        s.go("2026-03-09T11:00:02-07:00")
        #expect(s.host.started.count == 1, "the start time then passes without a second session")
    }

    @Test func aSecondMeetingLaterInTheWindowGetsItsOwnCard() throws {
        let s = Rig(events: [tenThirty, meeting("2026-03-09T11:30:00-07:00", "2026-03-09T11:45:00-07:00")])
        s.go("2026-03-09T08:59:00-07:00")
        s.scheduler.delay(s.host.cards[0].run)
        s.go("2026-03-09T10:59:00-07:00")
        let second = try #require(s.host.cards.last?.conflict)
        #expect(s.host.cards.last?.run.start == at("2026-03-09T11:00:00-07:00"))
        #expect(second.span.start == at("2026-03-09T11:30:00-07:00"))
        #expect(second.shortenEnd == at("2026-03-09T11:30:00-07:00"))
    }

    // MARK: Checked again at the click

    @Test func aMeetingThatMovedLaterIsUsedAtItsNewTime() throws {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.source.inner.events = [meeting("2026-03-09T10:45:00-07:00", "2026-03-09T11:15:00-07:00")]
        s.sayAt("2026-03-09T08:59:30-07:00")
        s.scheduler.shorten(s.host.cards[0].run)
        #expect(s.scheduler.adjustments["deep"]?.run.end == at("2026-03-09T10:45:00-07:00"), "not the 10:30 the card said")
    }

    @Test func aMeetingThatMovedEarlierIsUsedAtItsNewTimeForDelayToo() throws {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.source.inner.events = [meeting("2026-03-09T10:00:00-07:00", "2026-03-09T10:20:00-07:00")]
        s.scheduler.delay(s.host.cards[0].run)
        #expect(s.scheduler.adjustments["deep"]?.run.start == at("2026-03-09T10:20:00-07:00"))
    }

    @Test func aMeetingThatWasCancelledWithdrawsTheSuggestion() throws {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.source.inner.events = []
        s.scheduler.shorten(s.host.cards[0].run)
        #expect(s.scheduler.adjustments.isEmpty)
        #expect(s.host.logs.contains { $0.contains("no longer in the way") })
        s.go("2026-03-09T09:00:01-07:00")
        #expect(s.host.started.map(\.minutes) == [180], "the whole block, as scheduled")
    }

    @Test func aMeetingThatNowLeavesTooLittleWithdrawsTheChoiceAndShowsWhatIsLeft() throws {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        // Moved to 9:05: shortening would leave five minutes.
        s.source.inner.events = [meeting("2026-03-09T09:05:00-07:00", "2026-03-09T10:00:00-07:00")]
        s.scheduler.shorten(s.host.cards[0].run)
        #expect(s.scheduler.adjustments.isEmpty)
        #expect(s.host.cards.count == 2, "a new card replaces the stale one")
        #expect(s.host.cards[1].conflict?.shortenEnd == nil)
        #expect(s.host.cards[1].conflict?.delayStart == at("2026-03-09T10:00:00-07:00"))
    }

    @Test func aDoubleClickIsOneChoice() throws {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        let run = s.host.cards[0].run
        s.scheduler.delay(run)
        s.scheduler.delay(run)
        #expect(s.scheduler.adjustments["deep"]?.run.start == at("2026-03-09T11:00:00-07:00"))
        s.go("2026-03-09T11:00:01-07:00")
        s.go("2026-03-09T11:00:03-07:00", .wake)
        #expect(s.host.started.count == 1)
    }

    @Test func theCalendarIsReadAtTheHeadsUpAndTheClickAndNotBetween() {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:00:00-07:00")
        s.go("2026-03-09T08:30:00-07:00", .wake)
        #expect(s.source.reads == 0, "nothing polls")
        s.go("2026-03-09T08:59:00-07:00")
        s.go("2026-03-09T08:59:20-07:00", .wake)
        #expect(s.source.reads == 1, "once at the heads-up; the wake did not show it again")
        s.scheduler.shorten(s.host.cards[0].run)
        #expect(s.source.reads == 2, "and again when the choice is made")
        s.go("2026-03-09T09:00:01-07:00")
        s.go("2026-03-09T09:00:05-07:00", .timer)
        #expect(s.source.reads == 2, "starting reads nothing")
    }

    // MARK: A run starts once, and only when it may

    @Test func theSameHeadsUpTwiceIsOneCardAndOneRead() {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.go("2026-03-09T08:59:05-07:00", .wake)
        s.go("2026-03-09T08:59:10-07:00", .timer)
        #expect(s.host.cards.count == 1)
    }

    @Test func aShortenedRunStartsOnceWhateverLooksAtIt() {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.scheduler.shorten(s.host.cards[0].run)
        s.go("2026-03-09T09:00:01-07:00", .timer)
        s.go("2026-03-09T09:00:01.5-07:00", .wake)
        s.go("2026-03-09T09:00:30-07:00", .launch)
        s.host.isSessionOrBreakOn = false      // ended early
        s.go("2026-03-09T09:20:00-07:00", .wake)
        #expect(s.host.started.count == 1, "an ended session is not started again inside the window")
    }

    @Test func aDelayedRunStartsOnceWhateverLooksAtIt() {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.scheduler.delay(s.host.cards[0].run)
        s.go("2026-03-09T11:00:01-07:00", .timer)
        s.go("2026-03-09T11:00:03-07:00", .wake)
        s.host.isSessionOrBreakOn = false
        s.go("2026-03-09T11:20:00-07:00", .wake)
        s.go("2026-03-09T11:21:00-07:00", .launch)
        #expect(s.host.started.count == 1)
    }

    @Test func aDelayedRunDoesNotStartOverASessionOrBreak() {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.scheduler.delay(s.host.cards[0].run)
        s.host.isSessionOrBreakOn = true       // the person started one themselves
        s.go("2026-03-09T11:00:01-07:00")
        #expect(s.host.started.isEmpty)
        #expect(s.host.logs.contains { $0.contains("already on") })
        // When it ends, the delayed run is not started late: it was passed over.
        s.host.isSessionOrBreakOn = false
        s.go("2026-03-09T11:20:00-07:00", .wake)
        #expect(s.host.started.isEmpty)
        #expect(s.scheduler.adjustments.isEmpty)
    }

    @Test func noHeadsUpForADelayedRunWhileASessionIsOn() {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.scheduler.delay(s.host.cards[0].run)
        s.host.isSessionOrBreakOn = true
        s.go("2026-03-09T10:59:00-07:00")
        #expect(s.host.cards.count == 1)
    }

    @Test func aMacThatWasAsleepOrLockedThroughTheDelayedStartMakesItUpLate() throws {
        // The scheduler is not looked at while the Mac sleeps, and a lock gives
        // it no look of its own either: the first look is the wake (or the
        // launch), and the usual missed-start rules apply to the delayed run.
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.scheduler.delay(s.host.cards[0].run)
        s.go("2026-03-09T11:30:00-07:00", .wake)
        let first = try #require(s.host.started.first)
        #expect(first.missed)
        #expect(first.minutes == 30, "to the end of the window, from the wake")
        #expect(first.start == at("2026-03-09T11:00:00-07:00"))
    }

    @Test func aWakeWithUnderFiveMinutesOfTheDelayedWindowLeftStartsNothing() {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.scheduler.delay(s.host.cards[0].run)
        s.go("2026-03-09T11:56:00-07:00", .wake)
        #expect(s.host.started.isEmpty)
        s.go("2026-03-09T11:57:00-07:00", .timer)
        #expect(s.host.started.isEmpty, "and not tried again a minute later")
    }

    @Test func aWakeAfterTheWindowStartsNothingAndForgetsTheDelay() {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.scheduler.delay(s.host.cards[0].run)
        let next = s.go("2026-03-09T13:00:00-07:00", .wake)
        #expect(s.host.started.isEmpty)
        #expect(s.scheduler.adjustments.isEmpty)
        #expect(next == at("2026-03-10T08:59:00-07:00"), "tomorrow's heads-up")
    }

    @Test func aShortenedRunMadeUpAfterAWakeStillEndsAtTheMeeting() throws {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.scheduler.shorten(s.host.cards[0].run)
        s.go("2026-03-09T10:00:00-07:00", .wake)
        let first = try #require(s.host.started.first)
        #expect(first.missed && first.minutes == 30 && first.end == at("2026-03-09T10:30:00-07:00"))
    }

    @Test func aRelaunchDropsADelayedRunAndStartsNothingInItsPlace() {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.scheduler.delay(s.host.cards[0].run)
        // Nidus quits and opens again: a new scheduler, the same saved record.
        let clock = s.clock
        let reopened = FocusScheduler(host: s.host, now: { clock.now }, calendar: { losAngeles })
        let source = s.source
        reopened.calendarSource = { source }
        clock.now = at("2026-03-09T09:30:00-07:00")
        reopened.evaluate(.launch)
        clock.now = at("2026-03-09T11:00:01-07:00")
        reopened.evaluate(.timer)
        #expect(s.host.started.isEmpty, "the delay was in memory; the 9:00 run is already dealt with")
        #expect(s.host.scheduleHandled["deep"] == at("2026-03-09T09:00:00-07:00"))
    }

    // MARK: When the schedule changes

    @Test func movingTheScheduleDropsADelayedRun() {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.scheduler.delay(s.host.cards[0].run)
        s.host.schedules[0].setStart(ScheduleTime(hour: 9, minute: 30))
        s.go("2026-03-09T09:40:00-07:00", .edited)
        #expect(s.scheduler.adjustments.isEmpty)
        #expect(s.host.logs.contains { $0.contains("dropped") })
        s.go("2026-03-09T11:00:01-07:00")
        #expect(s.host.started.isEmpty)
    }

    @Test func turningTheScheduleOffOrDeletingItDropsADelayedRun() {
        let off = Rig(events: [tenThirty])
        off.go("2026-03-09T08:59:00-07:00")
        off.scheduler.delay(off.host.cards[0].run)
        off.host.schedules[0].isOn = false
        off.go("2026-03-09T09:40:00-07:00", .edited)
        #expect(off.scheduler.adjustments.isEmpty)

        let gone = Rig(events: [tenThirty])
        gone.go("2026-03-09T08:59:00-07:00")
        gone.scheduler.delay(gone.host.cards[0].run)
        gone.host.schedules = []
        gone.go("2026-03-09T09:40:00-07:00", .edited)
        #expect(gone.scheduler.adjustments.isEmpty)
    }

    @Test func aNewGoalIsUsedByADelayedRun() throws {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.scheduler.delay(s.host.cards[0].run)
        s.host.schedules[0].goal = "Write the aims"
        s.go("2026-03-09T09:40:00-07:00", .edited)
        #expect(s.scheduler.adjustments["deep"] != nil, "a goal is not a move")
        s.go("2026-03-09T11:00:01-07:00")
        #expect(s.host.started.first?.goal == "Write the aims")
    }

    @Test func turningTheOptionOffAfterTheCardWithdrawsTheClick() {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.host.schedules[0].checksCalendar = false
        s.scheduler.shorten(s.host.cards[0].run)
        #expect(s.scheduler.adjustments.isEmpty)
        s.go("2026-03-09T09:00:01-07:00")
        #expect(s.host.started.map(\.minutes) == [180])
    }

    @Test func aSessionStartedMeanwhileMakesTheClickDoNothing() {
        let s = Rig(events: [tenThirty])
        s.go("2026-03-09T08:59:00-07:00")
        s.host.isSessionOrBreakOn = true
        s.scheduler.delay(s.host.cards[0].run)
        #expect(s.scheduler.adjustments.isEmpty)
        #expect(s.host.scheduleHandled["deep"] == nil, "the run was not dealt with by a choice that did nothing")
    }

    // MARK: Zones, clock changes, midnight

    @Test func aZoneChangeBetweenTheCardAndTheClickDropsTheSuggestion() throws {
        let s = Rig(
            events: [meeting("2026-03-09T10:30:00-04:00", "2026-03-09T11:00:00-04:00")], calendar: newYork)
        s.sayAt("2026-03-09T08:00:00-04:00")
        s.go("2026-03-09T08:59:00-04:00")
        let card = try #require(s.host.cards.first)
        #expect(card.conflict?.shortenEnd == at("2026-03-09T10:30:00-04:00"))
        // The Mac lands in Los Angeles: 9:00 there is three hours later.
        s.scheduler.calendar = { losAngeles }
        s.sayAt("2026-03-09T08:59:30-04:00")
        s.scheduler.shorten(card.run)
        #expect(s.scheduler.adjustments.isEmpty, "the 9:00 on the card is not the 9:00 here")
        #expect(s.host.logs.contains { $0.contains("clock changed") })
        #expect(s.scheduler.nextWake == at("2026-03-09T08:59:00-07:00"), "looks again for the Los Angeles 9:00")
        s.go("2026-03-09T09:00:01-04:00", .clockChange)
        #expect(s.host.started.isEmpty, "5:00 AM in Los Angeles starts nothing")
    }

    @Test func aZoneChangeDropsADelayedRunMadeInTheOldZone() {
        let s = Rig(
            events: [meeting("2026-03-09T10:30:00-04:00", "2026-03-09T11:00:00-04:00")], calendar: newYork)
        s.go("2026-03-09T08:59:00-04:00")
        s.scheduler.delay(s.host.cards[0].run)
        #expect(s.scheduler.adjustments["deep"]?.run.start == at("2026-03-09T11:00:00-04:00"))
        s.scheduler.calendar = { losAngeles }
        s.go("2026-03-09T09:30:00-04:00", .clockChange)
        #expect(s.scheduler.adjustments.isEmpty)
        s.go("2026-03-09T11:00:01-04:00")
        #expect(s.host.started.isEmpty, "8:00 AM in Los Angeles")
    }

    @Test func aShortenedRunAcrossTheSpringForwardIsMeasuredInRealMinutes() throws {
        // Sunday March 8, Los Angeles. 1:00 AM to 5:00 AM, a meeting at 3:30.
        let s = Rig([schedule("night", (1, 0), (5, 0))],
                                       events: [meeting("2026-03-08T03:30:00-07:00", "2026-03-08T04:00:00-07:00")])
        s.sayAt("2026-03-08T00:00:00-08:00")
        s.go("2026-03-08T00:59:00-08:00")
        #expect(s.host.cards.first?.conflict?.shortenEnd == at("2026-03-08T03:30:00-07:00"))
        s.scheduler.shorten(s.host.cards[0].run)
        s.go("2026-03-08T01:00:01.5-08:00")
        let first = try #require(s.host.started.first)
        #expect(first.minutes == 89, "ninety minutes of the clock, not the 150 the wall reads")
    }

    @Test func aDelayedRunAcrossTheSpringForwardEndsWhereTheWindowDoes() throws {
        let s = Rig([schedule("night", (1, 0), (5, 0))],
                                       events: [meeting("2026-03-08T01:30:00-08:00", "2026-03-08T03:30:00-07:00")])
        s.sayAt("2026-03-08T00:00:00-08:00")
        s.go("2026-03-08T00:59:00-08:00")
        s.scheduler.delay(s.host.cards[0].run)
        #expect(s.scheduler.adjustments["night"]?.run.start == at("2026-03-08T03:30:00-07:00"))
        s.go("2026-03-08T03:30:01-07:00")
        let first = try #require(s.host.started.first)
        #expect(first.end == at("2026-03-08T05:00:00-07:00") && first.minutes == 90)
    }

    @Test func aShortenedRunAcrossTheFallBackIsMeasuredInRealMinutes() throws {
        // Sunday November 1: 12:30 AM to 3:00 AM is 3.5 hours, and the meeting
        // at the second 1:15 is 105 minutes in.
        let s = Rig([schedule("night", (0, 30), (3, 0))],
                                       events: [meeting("2026-11-01T01:15:00-08:00", "2026-11-01T02:00:00-08:00")])
        s.sayAt("2026-11-01T00:00:00-07:00")
        s.go("2026-11-01T00:29:00-07:00")
        s.scheduler.shorten(s.host.cards[0].run)
        s.go("2026-11-01T00:30:01.5-07:00")
        let first = try #require(s.host.started.first)
        #expect(first.minutes == 104)
        #expect(first.end == at("2026-11-01T01:15:00-08:00"))
    }

    @Test func aDelayedRunAcrossTheFallBackStartsAtTheMeetingsRealEnd() throws {
        let s = Rig([schedule("night", (0, 30), (3, 0))],
                                       events: [meeting("2026-11-01T01:00:00-07:00", "2026-11-01T01:20:00-08:00")])
        s.sayAt("2026-11-01T00:00:00-07:00")
        s.go("2026-11-01T00:29:00-07:00")
        let conflict = try #require(s.host.cards.first?.conflict)
        #expect(conflict.delayStart == at("2026-11-01T01:20:00-08:00"))
        s.scheduler.delay(s.host.cards[0].run)
        s.go("2026-11-01T01:20:01-08:00")
        #expect(s.host.started.first?.minutes == 100, "1:20 PST to 3:00 PST is 100 real minutes, though the wall reads 100 too after the repeated hour")
    }

    @Test func aDelayAcrossMidnightStartsAfterIt() throws {
        // A midnight to 2 AM block, with a meeting from yesterday evening to 12:45.
        let s = Rig([schedule("late", (0, 0), (2, 0), buffer: 5)],
                                       events: [meeting("2026-03-09T23:00:00-07:00", "2026-03-10T00:45:00-07:00")])
        s.sayAt("2026-03-09T22:00:00-07:00")
        s.go("2026-03-09T23:59:00-07:00")
        let conflict = try #require(s.host.cards.first?.conflict)
        #expect(conflict.startsDuring && conflict.shortenEnd == nil)
        #expect(conflict.delayStart == at("2026-03-10T00:50:00-07:00"))
        s.sayAt("2026-03-09T23:59:30-07:00")
        s.scheduler.delay(s.host.cards[0].run)
        s.go("2026-03-10T00:00:01-07:00")
        #expect(s.host.started.isEmpty)
        s.go("2026-03-10T00:50:01-07:00")
        #expect(s.host.started.first?.minutes == 70)
        #expect(s.host.started.first?.end == at("2026-03-10T02:00:00-07:00"))
    }

    @Test func aShortenWithAMeetingAfterMidnightIsFine() throws {
        let s = Rig([schedule("late", (23, 0), (23, 59))],
                                       events: [meeting("2026-03-09T23:30:00-07:00", "2026-03-10T00:30:00-07:00")])
        s.sayAt("2026-03-09T22:00:00-07:00")
        s.go("2026-03-09T22:59:00-07:00")
        let conflict = try #require(s.host.cards.first?.conflict)
        #expect(conflict.shortenEnd == at("2026-03-09T23:30:00-07:00"))
        #expect(conflict.delayStart == nil, "12:30 is after the block would have ended")
        s.scheduler.shorten(s.host.cards[0].run)
        s.go("2026-03-09T23:00:00-07:00")
        #expect(s.host.started.map(\.minutes) == [30])
    }

    // MARK: Existing behaviour

    @Test func existingSchedulesStartExactlyAsBefore() throws {
        // The same run, with and without the option, on a calendar with
        // nothing in it: identical starts.
        let plain = Rig([schedule(on: false)])
        let checked = Rig([schedule(on: true)])
        for rig in [plain, checked] {
            rig.go("2026-03-09T08:59:00-07:00")
            rig.go("2026-03-09T09:00:01-07:00")
        }
        #expect(plain.host.started.map(\.minutes) == checked.host.started.map(\.minutes))
        #expect(plain.host.started.map(\.minutes) == [180])
        #expect(plain.host.cards.count == 1 && checked.host.cards.count == 1)
    }
}
