//
//  FocusDurationParserTests.swift
//  NidusTests
//
//  The popover's "Custom…" length: minutes, hours and times of day to work
//  until, read from whatever is typed.
//

import Foundation
import Testing
@testable import Nidus

struct FocusDurationParserTests {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// A moment on Friday 25 September 2026, UTC.
    static func at(_ hour: Int, _ minute: Int = 0, second: Int = 0, day: Int = 25, calendar: Calendar = utc) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute, second: second))!
    }

    static func parse(_ text: String, now: Date = at(15)) -> Result<FocusDurationInput, FocusDurationParser.Failure> {
        FocusDurationParser.parse(text, now: now, calendar: utc)
    }

    // MARK: Minutes

    @Test(arguments: [
        ("40", 40), ("40m", 40), ("40 m", 40), ("40min", 40), ("40 mins", 40), ("40 minutes", 40),
        ("  40  ", 40), ("90 min", 90), ("90 minutes", 90), ("1", 1), ("1440", 1440), ("007", 7),
        ("40 MIN", 40), ("40\u{00A0}min", 40),
    ])
    func minutesAreRead(text: String, minutes: Int) {
        #expect(Self.parse(text) == .success(.minutes(minutes)), "\(text)")
    }

    @Test(arguments: [
        ("1h", 60), ("2h", 120), ("1h30", 90), ("1h30m", 90), ("1 h 30 m", 90), ("1 hr 30 min", 90), ("1hr30", 90),
        ("2 hours", 120), ("1 hour 30 minutes", 90), ("1.5h", 90), ("1.5 hours", 90), ("1,5h", 90), ("0.75h", 45),
        ("1.25h", 75), ("0h30", 30), ("24h", 1440), ("1H30M", 90), ("1h 5", 65),
    ])
    func hoursAreRead(text: String, minutes: Int) {
        #expect(Self.parse(text) == .success(.minutes(minutes)), "\(text)")
    }

    @Test(arguments: [("1:30", 90), ("0:45", 45), ("01:30", 90), ("2:00", 120), ("10:05", 605), ("24:00", 1440)])
    func aColonSeparatesHoursFromMinutes(text: String, minutes: Int) {
        #expect(Self.parse(text) == .success(.minutes(minutes)), "\(text) is a length, not a time of day")
    }

    @Test func whatThePopoverSaysIsWhatItReads() {
        for minutes in [1, 5, 15, 25, 45, 59, 60, 61, 90, 120, 125, 600, 1439, 1440] {
            let text = FocusFormat.duration(minutes: minutes)
            #expect(Self.parse(text) == .success(.minutes(minutes)), "\(text)")
        }
    }

    @Test(arguments: ["0", "00", "0m", "0h", "0:00", "1441", "25h", "24:01", "25:00", "2000 min", "99999999999999999999999"])
    func lengthsOutsideOneMinuteToADayAreOutOfRange(text: String) {
        #expect(Self.parse(text) == .failure(.outOfRange), "\(text)")
    }

    @Test(arguments: [
        "abc", "forty", "-5", "4 0", "1.5", "40.5m", "1h 30 30", "1h90", "1.5h30", "1:60", "1:5", "1:30:00", "h", "m",
        "min", "40 seconds", "1h30x", "until", "until banana", "until 3:60", "until 25:00", "until 3:5", "until 13pm",
        "until 0pm", "0pm", "40pm", "until 3:30 3", "until -3", "\u{1F600}",
    ])
    func whatIsNotALengthIsUnreadable(text: String) {
        #expect(Self.parse(text) == .failure(.unreadable), "\(text)")
    }

    @Test(arguments: ["", " ", "\n\t "])
    func nothingTypedIsEmptyNotAnError(text: String) {
        #expect(Self.parse(text) == .failure(.empty))
        #expect(FocusDurationParser.Failure.empty.hint == nil, "an empty field says nothing")
    }

    @Test func theHintsAreShortAndKind() {
        for failure: FocusDurationParser.Failure in [.unreadable, .outOfRange] {
            let hint = failure.hint ?? ""
            #expect(!hint.isEmpty && hint.hasSuffix("."))
            #expect(hint.count < 60, "it has to fit on one line under the field")
        }
    }

    // MARK: Times of day

    @Test(arguments: [
        "until 3:30pm", "until 3:30 pm", "until 3:30 PM", "until 3:30p.m.", "until 3:30 p.m.", "until 15:30", "until 3:30",
        "till 3:30pm", "until3:30pm", "  Until   3:30  PM ", "3:30pm", "3:30 PM", "until 3:30\u{202F}PM",
    ])
    func aTimeOfDayAtThreeThirty(text: String) {
        #expect(Self.parse(text) == .success(.until(Self.at(15, 30))), "\(text) at 3pm")
    }

    @Test func anHourAloneIsOnTheHour() {
        #expect(Self.parse("until 4pm") == .success(.until(Self.at(16))))
        #expect(Self.parse("until 4 pm") == .success(.until(Self.at(16))))
        #expect(Self.parse("4pm") == .success(.until(Self.at(16))))
        #expect(Self.parse("until 16") == .success(.until(Self.at(16))))
        #expect(Self.parse("until 4") == .success(.until(Self.at(16))), "4pm is the next 4 from 3pm")
    }

    @Test func aBareTimeIsALengthUnlessItSaysAMOrPM() {
        #expect(Self.parse("3:30") == .success(.minutes(210)))
        #expect(Self.parse("3:30pm") == .success(.until(Self.at(15, 30))))
    }

    @Test func aTimeThatHasPassedIsTomorrows() {
        let now = Self.at(16)
        #expect(Self.parse("until 3:30pm", now: now) == .success(.until(Self.at(15, 30, day: 26))))
        #expect(Self.parse("until 15:30", now: now) == .success(.until(Self.at(15, 30, day: 26))))
    }

    @Test func withoutAMOrPMTheNextOccurrenceOfEitherReadingWins() {
        // At 4pm "3:30" is 3:30 tomorrow morning: 11.5 hours, not 23.5.
        #expect(Self.parse("until 3:30", now: Self.at(16)) == .success(.until(Self.at(3, 30, day: 26))))
        // At 2pm it is this afternoon.
        #expect(Self.parse("until 3:30", now: Self.at(14)) == .success(.until(Self.at(15, 30))))
        // At 9pm, "7" is 7 tomorrow morning, 10 hours away.
        #expect(Self.parse("until 7", now: Self.at(21)) == .success(.until(Self.at(7, day: 26))))
        // At 9am, 12:30 is half past noon and not half past midnight.
        #expect(Self.parse("until 12:30", now: Self.at(9)) == .success(.until(Self.at(12, 30))))
        // At 11pm, it is half past midnight, next.
        #expect(Self.parse("until 12:30", now: Self.at(23)) == .success(.until(Self.at(0, 30, day: 26))))
    }

    @Test func aTwentyFourHourTimeMeansOnlyItself() {
        // 15:30 from 4pm is tomorrow, though 3:30 am is nearer: the 15 says which.
        #expect(Self.parse("until 15:30", now: Self.at(16)) == .success(.until(Self.at(15, 30, day: 26))))
        #expect(Self.parse("until 23:59") == .success(.until(Self.at(23, 59))))
        #expect(Self.parse("until 0:30") == .success(.until(Self.at(0, 30, day: 26))))
        #expect(Self.parse("until 00:30") == .success(.until(Self.at(0, 30, day: 26))))
        #expect(Self.parse("until 13") == .success(.until(Self.at(13, day: 26))))
    }

    @Test func noonAndMidnightWithAMOrPM() {
        #expect(Self.parse("until 12am") == .success(.until(Self.at(0, day: 26))))
        #expect(Self.parse("until 12pm") == .success(.until(Self.at(12, day: 26))))
        #expect(Self.parse("until 12:15 am", now: Self.at(23)) == .success(.until(Self.at(0, 15, day: 26))))
        #expect(Self.parse("until 12pm", now: Self.at(9)) == .success(.until(Self.at(12))))
    }

    @Test func theTimeItIsNowIsAFullCycleAway() {
        let now = Self.at(15)
        #expect(Self.parse("until 3pm", now: now) == .success(.until(Self.at(15, day: 26))), "explicit: tomorrow")
        #expect(Self.parse("until 15:00", now: now) == .success(.until(Self.at(15, day: 26))))
        #expect(Self.parse("until 3", now: now) == .success(.until(Self.at(3, day: 26))), "ambiguous: the next 3 o'clock, 12 hours off")
        // Half a minute into 3:30 is already past it.
        #expect(Self.parse("until 3:30pm", now: Self.at(15, 30, second: 30)) == .success(.until(Self.at(15, 30, day: 26))))
    }

    @Test func aTimeOfDayWithoutAMOrPMIsAlwaysWithinTwelveHours() {
        let twelveHours: TimeInterval = 12 * 3600
        for nowHour in 0..<24 {
            for nowMinute in [0, 7, 30, 59] {
                let now = Self.at(nowHour, nowMinute, second: 20)
                for hour in 1...12 {
                    for minute in [0, 15, 30, 45] {
                        let text = "until \(hour):" + String(format: "%02d", minute)
                        guard case .success(.until(let target)) = Self.parse(text, now: now) else {
                            Issue.record("\(text) at \(nowHour):\(nowMinute) was not read"); continue
                        }
                        let ahead = target.timeIntervalSince(now)
                        #expect(ahead > 0 && ahead <= twelveHours, "\(text) at \(nowHour):\(nowMinute) is \(ahead)s away")
                        let parts = Self.utc.dateComponents([.hour, .minute, .second], from: target)
                        #expect(parts.minute == minute && parts.second == 0 && parts.hour! % 12 == hour % 12)
                    }
                }
            }
        }
    }

    @Test func aTimeOfDayWithAMOrPMIsAlwaysWithinADay() {
        for nowHour in 0..<24 {
            let now = Self.at(nowHour, 10, second: 5)
            for text in ["until 1am", "until 6:45 pm", "until 12am", "until 12pm", "until 9:30pm"] {
                guard case .success(.until(let target)) = Self.parse(text, now: now) else {
                    Issue.record("\(text) was not read"); continue
                }
                let ahead = target.timeIntervalSince(now)
                #expect(ahead > 0 && ahead <= 24 * 3600, "\(text) at \(nowHour):10 is \(ahead)s away")
            }
        }
    }

    @Test func aSpringForwardDayIsCountedInRealTime() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        // 00:30 EST on 8 March 2026; at 2am the clocks jump to 3.
        let now = newYork.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0, minute: 30))!
        guard case .success(.until(let target)) = FocusDurationParser.parse("until 3:30", now: now, calendar: newYork) else {
            Issue.record("not read"); return
        }
        #expect(newYork.dateComponents([.hour, .minute], from: target).hour == 3)
        #expect(target.timeIntervalSince(now) == 2 * 3600, "an hour of that night does not exist")
    }

    // MARK: Minutes until a time

    @Test func minutesUntilARoundsUpAndStaysInRange() {
        let now = Self.at(15)
        #expect(FocusDurationParser.minutes(until: now.addingTimeInterval(25 * 60), from: now) == 25)
        #expect(FocusDurationParser.minutes(until: now.addingTimeInterval(25 * 60 + 1), from: now) == 26)
        #expect(FocusDurationParser.minutes(until: now.addingTimeInterval(25 * 60 - 1), from: now) == 25)
        #expect(FocusDurationParser.minutes(until: now.addingTimeInterval(20), from: now) == 1)
        #expect(FocusDurationParser.minutes(until: now, from: now) == 1, "never 0, which is open-ended")
        #expect(FocusDurationParser.minutes(until: now.addingTimeInterval(-3600), from: now) == 1, "never negative")
        #expect(FocusDurationParser.minutes(until: now.addingTimeInterval(3 * 86_400), from: now) == 1440)
        #expect(FocusDurationParser.minutes(until: .distantFuture, from: now) == 1440)
    }

    @Test func aSessionOfThoseMinutesEndsInTheTargetsOwnMinute() {
        // Started at 3:00:40 for "until 3:30": it ends at 3:30:40, which reads 3:30.
        let now = Self.at(15, 0, second: 40)
        let target = Self.at(15, 30)
        let minutes = FocusDurationParser.minutes(until: target, from: now)
        let end = now.addingTimeInterval(TimeInterval(minutes * 60))
        #expect(minutes == 30)
        #expect(Self.utc.dateComponents([.hour, .minute], from: end) == Self.utc.dateComponents([.hour, .minute], from: target))
    }
}
