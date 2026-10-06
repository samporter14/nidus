//
//  FocusLengthTests.swift
//  NidusTests
//
//  The popover's length (saved, custom or "until"), the running session's
//  quiet line, and the idle popover's line about today.
//

import Foundation
import Testing
@testable import Nidus

struct FocusLengthTests {
    static let en = Locale(identifier: "en_US")
    static let utc = TimeZone(identifier: "UTC")!
    static let now = FocusDurationParserTests.at(15)

    /// macOS writes a narrow no-break space before PM; compare with a plain one.
    static func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    // MARK: What the Length menu lists

    @Test func aSavedLengthThatIsNotStandardIsListedInOrderAheadOfOpenEnded() {
        let standard = [15, 25, 45, 60, 90, 0]
        #expect(FocusLength.choices(standard: standard, including: 40) == [15, 25, 40, 45, 60, 90, 0])
        #expect(FocusLength.choices(standard: standard, including: 5) == [5, 15, 25, 45, 60, 90, 0])
        #expect(FocusLength.choices(standard: standard, including: 1440) == [15, 25, 45, 60, 90, 1440, 0])
    }

    @Test func aStandardLengthAddsNothing() {
        let standard = [15, 25, 45, 60, 90, 0]
        for current in standard {
            #expect(FocusLength.choices(standard: standard, including: current) == standard)
        }
        #expect(FocusLength.choices(standard: standard, including: -3) == standard, "a corrupt saved value is not a choice")
    }

    // MARK: The one-off "until" time

    @Test func anUntilTimeIsPendingOnlyWhileItIsAhead() {
        let ahead = Self.now.addingTimeInterval(60)
        #expect(FocusLength.pending(ahead, now: Self.now) == ahead)
        #expect(FocusLength.pending(Self.now, now: Self.now) == nil)
        #expect(FocusLength.pending(Self.now.addingTimeInterval(-1), now: Self.now) == nil)
        #expect(FocusLength.pending(nil, now: Self.now) == nil)
    }

    @Test func theLengthButtonReadsTheUntilTimeOrTheSavedLength() {
        let target = FocusDurationParserTests.at(15, 30)
        func label(_ minutes: Int, _ until: Date?) -> String {
            Self.plain(FocusLength.label(durationMinutes: minutes, until: until, now: Self.now, locale: Self.en, timeZone: Self.utc))
        }
        #expect(label(25, target) == "Until 3:30 PM")
        #expect(label(25, nil) == "25 min")
        #expect(label(40, nil) == "40 min")
        #expect(label(0, nil) == "Open-ended")
        #expect(label(25, FocusDurationParserTests.at(14)) == "25 min", "a time that has passed is not a choice")
        let british = FocusLength.label(durationMinutes: 25, until: target, now: Self.now,
                                        locale: Locale(identifier: "en_GB"), timeZone: Self.utc)
        #expect(british == "Until 15:30", "the reader's own time style")
    }

    @Test func startComputesTheMinutesWhenItStarts() {
        let target = FocusDurationParserTests.at(15, 30)
        #expect(FocusLength.startMinutes(durationMinutes: 25, until: target, now: Self.now) == 30)
        // The same target, an hour of popover-left-open later: still ends at 3:30, if it still can.
        #expect(FocusLength.startMinutes(durationMinutes: 25, until: target, now: FocusDurationParserTests.at(15, 10)) == 20)
        #expect(FocusLength.startMinutes(durationMinutes: 25, until: target, now: FocusDurationParserTests.at(15, 29, second: 40)) == 1)
        #expect(FocusLength.startMinutes(durationMinutes: 25, until: nil, now: Self.now) == 25)
        #expect(FocusLength.startMinutes(durationMinutes: 0, until: nil, now: Self.now) == 0, "open-ended stays so")
        #expect(FocusLength.startMinutes(durationMinutes: 25, until: FocusDurationParserTests.at(14), now: Self.now) == 25,
                "a time that has passed falls back to the saved length, never 0 or less")
        #expect(FocusLength.startMinutes(durationMinutes: 0, until: target, now: Self.now) == 30, "an until time wins over open-ended")
    }

    // MARK: Under the custom field

    @Test func theCaptionHintsThenPreviewsThenOnlyScoldsAfterAReturn() {
        func caption(_ text: String, rejected: FocusDurationParser.Failure? = nil) -> CustomLengthDraft.Caption {
            let c = CustomLengthDraft(text: text, rejected: rejected).caption(
                now: Self.now, calendar: FocusDurationParserTests.utc, locale: Self.en, timeZone: Self.utc)
            if case .preview(let text) = c { return .preview(Self.plain(text)) }
            return c
        }
        #expect(caption("") == .hint(CustomLengthDraft.example))
        #expect(caption("1h30") == .preview("1 hr 30 min"))
        #expect(caption("40") == .preview("40 min"))
        #expect(caption("until 3:30pm") == .preview("Until 3:30 PM"))
        #expect(caption("unt") == .hint(CustomLengthDraft.example), "half typed is not an error")
        #expect(caption("banana") == .hint(CustomLengthDraft.example), "nor is a guess, until Return")
        #expect(caption("banana", rejected: .unreadable) == .problem(FocusDurationParser.Failure.unreadable.hint!))
        #expect(caption("2000", rejected: .outOfRange) == .problem(FocusDurationParser.Failure.outOfRange.hint!))
    }
}

struct FocusRunningLineTests {
    static let en = Locale(identifier: "en_US")
    static let utc = TimeZone(identifier: "UTC")!
    static let started = FocusDurationParserTests.at(14, 15)
    static let ends = FocusDurationParserTests.at(15, 40)

    func line(paused: Bool = false, blocking: Bool = true, endsAt: Date? = ends, blocked: Int = 0,
              locale: Locale = en) -> String {
        FocusLengthTests.plain(FocusFormat.runningLine(paused: paused, blocking: blocking, endsAt: endsAt, startedAt: Self.started,
                                                       blocked: blocked, locale: locale, timeZone: Self.utc))
    }

    @Test func aTimedSessionSaysWhenItEnds() {
        #expect(line() == "Until 3:40 PM")
        #expect(line(blocked: 2) == "Until 3:40 PM · blocked 2 times")
        #expect(line(blocked: 14) == "Until 3:40 PM · blocked 14 times")
    }

    @Test func oneBlockIsOnceNotOneTimes() {
        #expect(line(blocked: 1) == "Until 3:40 PM · blocked once")
    }

    @Test func anOpenEndedSessionSaysWhenItBegan() {
        #expect(line(endsAt: nil) == "Started 2:15 PM")
        #expect(line(endsAt: nil, blocked: 2) == "Started 2:15 PM · blocked 2 times")
    }

    @Test func aPauseSaysSoAndThatNothingIsBlockedWhileItLasts() {
        #expect(line(paused: true, blocking: false) == "Paused · not blocking")
        #expect(line(paused: true, blocking: false, endsAt: nil, blocked: 3) == "Paused · not blocking")
        #expect(line(paused: true, blocking: true) == "Paused", "paused by sleep or the lock screen still blocks")
    }

    @Test func theTimeIsInTheReadersOwnStyle() {
        #expect(line(locale: Locale(identifier: "en_GB")) == "Until 15:40")
    }
}

struct FocusTodayLineTests {
    @Test func todayAndAStreak() {
        #expect(FocusFormat.todayLine(focused: 70 * 60, streak: 3) == "Today 1 hr 10 min · 3-day streak")
        #expect(FocusFormat.todayLine(focused: 25 * 60, streak: 2) == "Today 25 min · 2-day streak")
    }

    @Test func aStreakOfOneIsNotNamed() {
        #expect(FocusFormat.todayLine(focused: 25 * 60, streak: 1) == "Today 25 min")
        #expect(FocusFormat.todayLine(focused: 25 * 60, streak: 0) == "Today 25 min")
    }

    @Test func anEmptyDayShowsOnlyAStreakWaitingToBeCarriedOn() {
        #expect(FocusFormat.todayLine(focused: 0, streak: 3) == "No focus yet today · 3-day streak")
        #expect(FocusFormat.todayLine(focused: 0, streak: 2) == "No focus yet today · 2-day streak")
        #expect(FocusFormat.todayLine(focused: 0, streak: 1) == nil, "yesterday alone is not a streak")
        #expect(FocusFormat.todayLine(focused: 0, streak: 0) == nil, "a first run is not greeted with a zero")
    }

    @Test func aMinuteIsTheLeastItSays() {
        #expect(FocusFormat.todayLine(focused: 20, streak: 0) == "Today 1 min", "never Today 0 min, nor Today Open-ended")
        #expect(FocusFormat.todayLine(focused: 90, streak: 0) == "Today 2 min")
    }
}

struct FocusedTodayTests {
    typealias S = StatsTests
    func stats(_ sessions: [SessionEntry], now: Date = S.now, weeks: Int = 26) -> FocusStats {
        FocusStats(sessions: sessions, now: now, calendar: S.calendar, weeks: weeks)
    }

    @Test func todayIsOnlyTodaysSessions() {
        let sessions = [S.entry(-2, minutes: 40), S.entry(-1, minutes: 30), S.entry(0, minutes: 25), S.entry(0, minutes: 45)]
        #expect(stats(sessions).focusedToday == 70 * 60)
    }

    @Test func aDayWithNothingIsZero() {
        #expect(stats([]).focusedToday == 0)
        #expect(stats([S.entry(-1, minutes: 30)]).focusedToday == 0)
    }

    @Test func oneWeekOfDaysIsEnoughForToday() {
        let sessions = [S.entry(-1, minutes: 30), S.entry(0, minutes: 25)]
        #expect(stats(sessions, weeks: 1).focusedToday == 25 * 60)
        #expect(stats(sessions, weeks: 1).currentStreak == 2, "and the streak still reads the whole history")
    }

    @Test func midnightIsTheBoundary() {
        // Friday 25 September 2026, UTC: 23:30 on the 24th is yesterday's, 00:10 on the 25th is today's.
        let late = SessionEntry(start: S.day(-1, hour: 23).addingTimeInterval(30 * 60), end: S.day(0, hour: 0), focused: 30 * 60,
                                planned: 30 * 60, outcome: .completed)
        let early = SessionEntry(start: S.day(0, hour: 0).addingTimeInterval(10 * 60), end: S.day(0, hour: 1), focused: 50 * 60,
                                 planned: 50 * 60, outcome: .completed)
        #expect(stats([late, early]).focusedToday == 50 * 60)
    }

    @Test func todayFollowsTheNowItWasMadeWith() {
        let sessions = [S.entry(0, minutes: 25)]
        let tomorrow = S.calendar.date(byAdding: .day, value: 1, to: S.now)!
        #expect(stats(sessions, now: tomorrow).focusedToday == 0)
        #expect(stats(sessions, now: tomorrow).currentStreak == 1, "yesterday's focus keeps the streak alive")
    }

    @Test func whatTheFooterSaysComesFromTheStats() {
        let sessions = [S.entry(-2, minutes: 25), S.entry(-1, minutes: 25), S.entry(0, minutes: 45), S.entry(0, minutes: 25)]
        let s = stats(sessions, weeks: 1)
        #expect(FocusFormat.todayLine(focused: s.focusedToday, streak: s.currentStreak) == "Today 1 hr 10 min · 3-day streak")
        let waiting = stats(Array(sessions.prefix(2)), weeks: 1)
        #expect(FocusFormat.todayLine(focused: waiting.focusedToday, streak: waiting.currentStreak) == "No focus yet today · 2-day streak")
    }
}
