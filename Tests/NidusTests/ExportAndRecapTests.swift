//
//  ExportAndRecapTests.swift
//  NidusTests
//
//  Exporting the history as CSV and JSON, Monday's recap card, and the
//  Stats page's plain numbers.
//

import Foundation
import Testing
@testable import Nidus

/// Dates in a named time zone, so a test says "Sunday 23:30 in New York"
/// and means it.
struct ZonedCalendar {
    let calendar: Calendar

    init(_ identifier: String, firstWeekday: Int = 2) {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: identifier)!
        c.locale = Locale(identifier: "en_US")
        c.firstWeekday = firstWeekday
        calendar = c
    }

    func date(_ y: Int, _ m: Int, _ d: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))!
    }
}

/// Reads CSV the way RFC 4180 says, so the tests can check what was written
/// by reading it back rather than by comparing strings.
func parseCSV(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    let scalars = Array(text.unicodeScalars)
    var i = 0
    while i < scalars.count {
        let c = scalars[i]
        if quoted {
            if c == "\"" {
                if i + 1 < scalars.count, scalars[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 } else { quoted = false }
            } else {
                field.unicodeScalars.append(c)
            }
        } else if c == "\"" {
            quoted = true
        } else if c == "," {
            row.append(field); field = ""
        } else if c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" {
            row.append(field); field = ""; rows.append(row); row = []; i += 1
        } else {
            field.unicodeScalars.append(c)
        }
        i += 1
    }
    if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
    return rows
}

// MARK: - Export

struct HistoryExportTests {
    static let la = ZonedCalendar("America/Los_Angeles")

    static func entry(_ start: Date, minutes: Double = 25, planned: Double? = 25, outcome: SessionEndReason = .completed,
                      goal: String = "", finished: Bool? = nil, blocks: [String: Int] = [:],
                      names: [String: String] = [:]) -> SessionEntry {
        SessionEntry(start: start, end: start.addingTimeInterval(minutes * 60 + 30), focused: minutes * 60,
                     planned: planned.map { $0 * 60 }, outcome: outcome, goal: goal, blocks: blocks, names: names,
                     finished: finished)
    }

    @Test func aRowHasEveryColumnAndTimesCarryTheirOffset() {
        let start = Self.la.date(2026, 9, 28, 9, 15)
        let e = Self.entry(start, goal: "Write the launch post", finished: true,
                           blocks: ["youtube.com": 3, "com.tinyspeck.slackmacgap": 1],
                           names: ["com.tinyspeck.slackmacgap": "Slack"])
        let rows = parseCSV(HistoryExport.csv([e], timeZone: Self.la.calendar.timeZone))
        #expect(rows.count == 2)
        #expect(rows[0] == ["start", "end", "planned_minutes", "focused_minutes", "completed", "goal", "finished",
                            "blocked_count", "most_blocked"])
        #expect(rows[1] == ["2026-09-28T09:15:00-07:00", "2026-09-28T09:40:30-07:00", "25", "25", "yes",
                            "Write the launch post", "yes", "4", "youtube.com"])
    }

    @Test(arguments: [("Asia/Kolkata", "+05:30"), ("UTC", "+00:00"), ("America/New_York", "-04:00")])
    func theOffsetIsAlwaysWrittenOut(_ zone: String, _ offset: String) {
        let when = ZonedCalendar(zone).date(2026, 9, 28, 12, 0)
        let rows = parseCSV(HistoryExport.csv([Self.entry(when)], timeZone: TimeZone(identifier: zone)!))
        #expect(rows[1][0] == "2026-09-28T12:00:00" + offset, "UTC is +00:00, never Z")
    }

    @Test func goalsWithCommasQuotesAndLineBreaksComeBackWhole() {
        let goals = ["Plan, then write", "Say \"hello\"", "Line one\nline two", "Windows\r\nbreak", "\"", ",", "  padded  ", "plain",
                     "Ends with a quote\"", "Ünïcode, naïve"]
        let sessions = goals.map { Self.entry(Self.la.date(2026, 9, 28, 9), goal: $0) }
        let rows = parseCSV(HistoryExport.csv(sessions, timeZone: Self.la.calendar.timeZone))
        #expect(rows.count == goals.count + 1, "a newline inside a goal does not start a row")
        #expect(rows.dropFirst().map { $0[5] } == goals)
        #expect(rows.allSatisfy { $0.count == HistoryExport.csvColumns.count })
    }

    @Test func fieldsAreQuotedOnlyWhenTheyNeedIt() {
        #expect(HistoryExport.field("plain text") == "plain text")
        #expect(HistoryExport.field("a,b") == "\"a,b\"")
        #expect(HistoryExport.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(HistoryExport.field("one\ntwo") == "\"one\ntwo\"")
        #expect(HistoryExport.field("one\r\ntwo") == "\"one\r\ntwo\"", "CR LF is one Character in Swift and still needs quoting")
        #expect(HistoryExport.field("") == "")
    }

    @Test func anOpenEndedSessionHasNoPlannedMinutesAndNoAnswerIsBlank() {
        let open = Self.entry(Self.la.date(2026, 9, 28, 9), minutes: 52.5, planned: nil, outcome: .endedEarly)
        let rows = parseCSV(HistoryExport.csv([open], timeZone: Self.la.calendar.timeZone))
        #expect(rows[1][2] == "", "planned minutes")
        #expect(rows[1][3] == "52.5", "focused minutes keep a half minute")
        #expect(rows[1][4] == "no", "completed")
        #expect(rows[1][6] == "", "finished: never asked")
        #expect(rows[1][7] == "0" && rows[1][8] == "", "nothing blocked")
    }

    @Test func finishedIsYesNoOrBlank() {
        let day = Self.la.date(2026, 9, 28, 9)
        let rows = parseCSV(HistoryExport.csv([Self.entry(day, goal: "a", finished: true), Self.entry(day, goal: "b", finished: false),
                                               Self.entry(day, goal: "c", finished: nil)],
                                              timeZone: Self.la.calendar.timeZone))
        #expect(rows.dropFirst().map { $0[6] } == ["yes", "no", ""])
    }

    @Test func completedMeansTheCountdownReachedZero() {
        let day = Self.la.date(2026, 9, 28, 9)
        let rows = parseCSV(HistoryExport.csv(([.completed, .endedEarly, .expiredWhileAway] as [SessionEndReason]).map { Self.entry(day, outcome: $0) },
                                              timeZone: Self.la.calendar.timeZone))
        #expect(rows.dropFirst().map { $0[4] } == ["yes", "no", "no"])
    }

    @Test func anEmptyHistoryIsJustTheHeader() {
        let text = HistoryExport.csv([], timeZone: TimeZone(identifier: "UTC")!)
        #expect(text == HistoryExport.csvColumns.joined(separator: ",") + "\r\n")
        #expect(parseCSV(text).count == 1)
    }

    @Test func theMostBlockedItemIsNamedAndTiesGoAlphabetically() {
        let names = ["com.tinyspeck.slackmacgap": "Slack", "com.apple.mail": "Mail"]
        func most(_ blocks: [String: Int]) -> String {
            HistoryExport.mostBlocked(in: Self.entry(Self.la.date(2026, 9, 28, 9), blocks: blocks, names: names))
        }
        #expect(most(["youtube.com": 2, "com.tinyspeck.slackmacgap": 5]) == "Slack", "a display name, not the bundle id")
        #expect(most(["x.com": 3]) == "x.com", "no name on file: the key itself")
        #expect(most(["com.tinyspeck.slackmacgap": 2, "com.apple.mail": 2, "youtube.com": 2]) == "Mail", "a tie is the first by name")
        #expect(most([:]) == "")
        #expect(most(["x.com": 0]) == "")
    }

    @Test(arguments: [(0.0, "0"), (60.0, "1"), (1500.0, "25"), (1530.0, "25.5"), (1499.0, "25"), (3700.0, "61.7")])
    func minutesCarryOneDecimalAtMost(_ seconds: Double, _ expected: String) {
        #expect(HistoryExport.minutes(seconds) == expected)
    }

    @Test func theJSONIsTheHistoryFileItself() throws {
        let day = Self.la.date(2026, 9, 28, 9)
        let sessions = [Self.entry(day, goal: "One", finished: true, blocks: ["youtube.com": 2, "x.com": 1], names: ["x.com": "x.com"]),
                        Self.entry(day.addingTimeInterval(7200), minutes: 40, planned: nil, outcome: .endedEarly)]
        let data = try HistoryExport.json(sessions)
        let file = try JSONDecoder().decode(FocusHistory.File.self, from: data)
        #expect(file.version == 1)
        #expect(file.sessions == sessions, "every field, as stored")
        // The same bytes go to disk: what Bench and Agent Day read.
        let saved = try JSONDecoder().decode(FocusHistory.File.self, from: FocusHistory.encode(sessions))
        #expect(saved.sessions == file.sessions)
    }

    @Test func anEmptyHistoryIsAnEmptyList() throws {
        let file = try JSONDecoder().decode(FocusHistory.File.self, from: HistoryExport.json([]))
        #expect(file.sessions.isEmpty)
    }

    @MainActor
    @Test func anExportedFileLoadsBackIntoNidus() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("focus-export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let sessions = [StatsTests.entry(-1, minutes: 25), StatsTests.entry(-2, minutes: 45)]
        try HistoryExport.json(sessions).write(to: url)
        #expect(FocusHistory(url: url).sessions == sessions)
    }

    @Test func formatsKnowTheirExtensions() {
        #expect(HistoryExport.Format.csv.fileExtension == "csv")
        #expect(HistoryExport.Format.json.fileExtension == "json")
    }
}

// MARK: - Weekly recap

struct WeeklyRecapTests {
    static let ny = ZonedCalendar("America/New_York")

    /// A session of `minutes` starting at `start`.
    static func session(_ start: Date, minutes: Double = 25, finished: Bool? = nil) -> SessionEntry {
        SessionEntry(start: start, end: start.addingTimeInterval(minutes * 60), focused: minutes * 60,
                     planned: minutes * 60, outcome: .completed, goal: finished == nil ? "" : "Goal", finished: finished)
    }

    // The week of Monday 21 to Sunday 27 September 2026, and the Monday after.
    static let lastWeek = [session(ny.date(2026, 9, 22, 10), minutes: 60)]
    static let mondayMorning = ny.date(2026, 9, 28, 9, 0)

    // MARK: Boundaries

    @Test func weeksRunMondayToSundayWhateverTheLocaleStartsOn() {
        for firstWeekday in [1, 2, 7] {
            let z = ZonedCalendar("America/New_York", firstWeekday: firstWeekday)
            let monday = z.date(2026, 9, 21)
            for (date, expected) in [(z.date(2026, 9, 21, 0, 0), monday), (z.date(2026, 9, 23, 15), monday),
                                     (z.date(2026, 9, 27, 23, 59), monday), (z.date(2026, 9, 28, 0, 0), z.date(2026, 9, 28)),
                                     (z.date(2026, 9, 20, 23, 59), z.date(2026, 9, 14))] {
                #expect(WeeklyRecap.monday(onOrBefore: date, calendar: z.calendar) == expected, "first weekday \(firstWeekday)")
            }
        }
    }

    @Test func theCardIsDueFromMondayAtNineAndNotBefore() {
        let sessions = Self.lastWeek
        func due(_ now: Date) -> WeeklyRecap? { WeeklyRecap.due(sessions: sessions, now: now, shownWeek: nil, calendar: Self.ny.calendar) }
        #expect(due(Self.ny.date(2026, 9, 28, 0, 0)) == nil)
        #expect(due(Self.ny.date(2026, 9, 28, 8, 59)) == nil)
        #expect(due(Self.ny.date(2026, 9, 28, 9, 0))?.weekID == "2026-09-21")
        #expect(due(Self.ny.date(2026, 9, 28, 23, 59)) != nil)
    }

    @Test func aMissedMondayIsStillDueTheRestOfTheWeek() {
        let tuesday = Self.ny.date(2026, 9, 29, 8, 0)
        #expect(WeeklyRecap.due(sessions: Self.lastWeek, now: tuesday, shownWeek: nil, calendar: Self.ny.calendar) != nil)
        let sunday = Self.ny.date(2026, 10, 4, 22, 0)
        #expect(WeeklyRecap.due(sessions: Self.lastWeek, now: sunday, shownWeek: nil, calendar: Self.ny.calendar) != nil)
        // The Monday after, it is another week's turn: that one had nothing.
        let nextMonday = Self.ny.date(2026, 10, 5, 9, 0)
        #expect(WeeklyRecap.due(sessions: Self.lastWeek, now: nextMonday, shownWeek: nil, calendar: Self.ny.calendar) == nil)
    }

    @Test func aWeekIsShownOnce() {
        let now = Self.ny.date(2026, 9, 29, 12)
        #expect(WeeklyRecap.due(sessions: Self.lastWeek, now: now, shownWeek: "2026-09-21", calendar: Self.ny.calendar) == nil)
        #expect(WeeklyRecap.due(sessions: Self.lastWeek, now: now, shownWeek: "2026-09-14", calendar: Self.ny.calendar) != nil,
                "an older week's mark does not hide this one")
    }

    @Test func neverDuringASessionOrWithHistoryOff() {
        let now = Self.mondayMorning
        #expect(WeeklyRecap.due(sessions: Self.lastWeek, now: now, shownWeek: nil, idle: false, calendar: Self.ny.calendar) == nil)
        #expect(WeeklyRecap.due(sessions: Self.lastWeek, now: now, shownWeek: nil, recording: false, calendar: Self.ny.calendar) == nil)
        #expect(WeeklyRecap.due(sessions: Self.lastWeek, now: now, shownWeek: nil, calendar: Self.ny.calendar) != nil,
                "and it is still there once the session is over")
    }

    @Test func aWeekWithNoSessionsHasNoRecap() {
        let thisWeekOnly = [Self.session(Self.ny.date(2026, 9, 29, 10))]
        let now = Self.ny.date(2026, 9, 30, 10)
        #expect(WeeklyRecap.due(sessions: thisWeekOnly, now: now, shownWeek: nil, calendar: Self.ny.calendar) == nil)
        #expect(WeeklyRecap.due(sessions: [], now: now, shownWeek: nil, calendar: Self.ny.calendar) == nil)
        #expect(WeeklyRecap(sessions: [], weekStarting: Self.ny.date(2026, 9, 21), calendar: Self.ny.calendar) == nil)
    }

    @Test func aSessionBelongsToTheWeekItStartedIn() {
        let z = Self.ny
        let sessions = [
            Self.session(z.date(2026, 9, 20, 23, 59)),  // Sunday before: not in
            Self.session(z.date(2026, 9, 21, 0, 0)),     // Monday midnight: in
            Self.session(z.date(2026, 9, 27, 23, 30), minutes: 90),  // Sunday night, runs past midnight: in
            Self.session(z.date(2026, 9, 28, 0, 10)),    // Monday just after: not in
        ]
        let recap = WeeklyRecap(sessions: sessions, weekStarting: z.date(2026, 9, 21), calendar: z.calendar)
        #expect(recap?.sessionCount == 2)
        let expected: TimeInterval = 115 * 60
        #expect(recap?.focused == expected)
    }

    @Test func theWeekIsTheCalendarsOwnTimeZone() {
        // 03:00 UTC on Monday is still Sunday evening in Los Angeles.
        let moment = Date(timeIntervalSince1970: ZonedCalendar("UTC").date(2026, 9, 28, 3).timeIntervalSince1970)
        let la = ZonedCalendar("America/Los_Angeles"), utc = ZonedCalendar("UTC")
        let inLA = WeeklyRecap(sessions: [Self.session(moment)], weekStarting: la.date(2026, 9, 21), calendar: la.calendar)
        let inUTC = WeeklyRecap(sessions: [Self.session(moment)], weekStarting: utc.date(2026, 9, 21), calendar: utc.calendar)
        #expect(inLA?.sessionCount == 1)
        #expect(inUTC == nil)
        #expect(inLA?.bestDayName == "Sunday")
    }

    @Test func aWeekThatEndsWhenTheClocksGoBack() {
        // 1 November 2026 has 25 hours in New York. Its 23:30 is still that Sunday's.
        let z = Self.ny
        let monday = z.date(2026, 10, 26)
        #expect(WeeklyRecap.monday(onOrBefore: z.date(2026, 11, 1, 23, 59), calendar: z.calendar) == monday)
        #expect(WeeklyRecap.monday(onOrBefore: z.date(2026, 11, 2, 0, 5), calendar: z.calendar) == z.date(2026, 11, 2))
        let sessions = [Self.session(z.date(2026, 10, 26, 0, 0)), Self.session(z.date(2026, 11, 1, 23, 30)),
                        Self.session(z.date(2026, 11, 2, 0, 10))]
        let before = WeeklyRecap.due(sessions: sessions, now: z.date(2026, 11, 2, 8, 59), shownWeek: nil, calendar: z.calendar)
        #expect(before == nil)
        let recap = WeeklyRecap.due(sessions: sessions, now: z.date(2026, 11, 2, 9, 0), shownWeek: nil, calendar: z.calendar)
        #expect(recap?.weekID == "2026-10-26")
        #expect(recap?.sessionCount == 2)
        #expect(recap?.weekStart == monday)
    }

    // MARK: Contents

    @Test func theBestDayIsTheOneWithMostFocusAndAnEarlierDayWinsATie() {
        let z = Self.ny
        let sessions = [Self.session(z.date(2026, 9, 21, 9), minutes: 30), Self.session(z.date(2026, 9, 22, 9), minutes: 25),
                        Self.session(z.date(2026, 9, 22, 14), minutes: 25), Self.session(z.date(2026, 9, 24, 9), minutes: 50)]
        // Tuesday has 50 minutes over two sessions, Thursday 50 in one: Tuesday is first.
        #expect(WeeklyRecap(sessions: sessions, weekStarting: z.date(2026, 9, 21), calendar: z.calendar)?.bestDayName == "Tuesday")
        let more = sessions + [Self.session(z.date(2026, 9, 25, 9), minutes: 51)]
        let recap = WeeklyRecap(sessions: more, weekStarting: z.date(2026, 9, 21), calendar: z.calendar)
        #expect(recap?.bestDayName == "Friday")
        #expect(recap?.bestDay == z.date(2026, 9, 25))
    }

    /// 14 sessions and 6 hr 20 min, most of it on the Tuesday, 3 goals finished.
    static var busyWeek: [SessionEntry] {
        let z = ny
        var sessions = (0..<8).map { Self.session(z.date(2026, 9, 22, 8 + $0), minutes: 40, finished: $0 < 3 ? true : ($0 < 5 ? false : nil)) }
        sessions += (0..<6).map { Self.session(z.date(2026, 9, 24 + $0 / 3, 9 + $0 % 3), minutes: 10) }
        // 8 * 40 + 6 * 10 = 380 minutes.
        return sessions
    }

    @Test func theCardSaysWhatTheSpecSays() {
        let recap = WeeklyRecap(sessions: Self.busyWeek, weekStarting: Self.ny.date(2026, 9, 21), calendar: Self.ny.calendar)
        #expect(recap?.title == "Last week: 6 hr 20 min")
        #expect(recap?.detail == "14 sessions \u{00B7} best day Tuesday \u{00B7} 3 goals finished")
    }

    @Test func partsThatAreZeroAreLeftOut() {
        let z = Self.ny
        let none = WeeklyRecap(sessions: [Self.session(z.date(2026, 9, 23, 9), minutes: 45)], weekStarting: z.date(2026, 9, 21), calendar: z.calendar)
        #expect(none?.detail == "1 session \u{00B7} best day Wednesday", "no goals finished, so no goals part; one session is singular")
        #expect(none?.title == "Last week: 45 min")
        let one = WeeklyRecap(sessions: [Self.session(z.date(2026, 9, 23, 9), finished: true)], weekStarting: z.date(2026, 9, 21), calendar: z.calendar)
        #expect(one?.detail == "1 session \u{00B7} best day Wednesday \u{00B7} 1 goal finished")
        let unanswered = WeeklyRecap(sessions: [Self.session(z.date(2026, 9, 23, 9), finished: false)], weekStarting: z.date(2026, 9, 21), calendar: z.calendar)
        #expect(unanswered?.goalsFinished == 0, "a goal answered not yet is not finished")
    }

    @Test func theSpokenFormReadsInOnePass() {
        let recap = WeeklyRecap(sessions: Self.busyWeek, weekStarting: Self.ny.date(2026, 9, 21), calendar: Self.ny.calendar)
        #expect(recap?.spoken == "Last week: 6 hr 20 min. 14 sessions, best day Tuesday, 3 goals finished.")
    }
}

// MARK: - Stats page

struct StatsPageTests {
    @Test func zeroIsWrittenAsZero() {
        #expect(FocusFormat.days(0) == "0 days")
        #expect(FocusFormat.days(1) == "1 day")
        #expect(FocusFormat.days(12) == "12 days")
        #expect(FocusFormat.long(0) == "0 min")
    }

    @Test func theSampleHistoryHasEightWeeksAndAStreakAndRecapsLastWeek() {
        let z = ZonedCalendar("America/New_York")
        let now = z.date(2026, 10, 5, 14)
        let sessions = SampleHistory.entries(now: now, calendar: z.calendar)
        #expect(sessions.allSatisfy { $0.focused >= SessionEntry.minimumFocus })
        #expect(sessions.map(\.start) == SampleHistory.entries(now: now, calendar: z.calendar).map(\.start), "the same every time")
        let stats = FocusStats(sessions: sessions, now: now, calendar: z.calendar)
        #expect(stats.currentStreak >= 3)
        #expect(stats.goalsFinished > 0 && stats.mostBlocked != nil)
        let first = sessions.map(\.start).min()!
        #expect(z.calendar.dateComponents([.day], from: first, to: now).day! >= 50, "about eight weeks back")
        #expect(WeeklyRecap.due(sessions: sessions, now: now, shownWeek: nil, calendar: z.calendar) != nil)
    }
}
