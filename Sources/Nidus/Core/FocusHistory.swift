//
//  FocusHistory.swift
//  Nidus
//
//  The record of finished sessions, and the stats worked out from it. It is
//  a JSON file in Nidus's folder and never leaves the Mac; the
//  settings page says so and can clear it.
//
//  No DroppyKit import: this file also compiles into the tests.
//

import Foundation

/// One finished session.
struct SessionEntry: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var start: Date
    var end: Date
    /// Time focused, pauses excluded.
    var focused: TimeInterval
    /// The length planned, extensions included; nil when open-ended.
    var planned: TimeInterval?
    var outcome: SessionEndReason
    var goal: String
    /// App (bundle identifier) or site (domain) to times blocked.
    var blocks: [String: Int]
    /// App to times quit.
    var quits: [String: Int]
    /// App to seconds frontmost while the session ran.
    var foreground: [String: TimeInterval]
    /// Display names for every key above.
    var names: [String: String]
    /// Whether the goal was finished, as answered on the wrap-up card. nil
    /// when there was no goal or no answer. Older files have none.
    var finished: Bool?

    /// The entry for a session that just ended, or nil for one too short to
    /// count (started by mistake and ended at once).
    init?(ended state: SessionState, outcome: SessionEndReason) {
        let focused = state.focusedTime ?? 0
        guard focused >= SessionEntry.minimumFocus else { return nil }
        start = state.startedAt
        end = state.endedAt ?? state.startedAt.addingTimeInterval(focused)
        self.focused = focused
        planned = state.plan.duration == nil ? nil : state.budget
        self.outcome = outcome
        goal = state.plan.goal
        blocks = state.blocks
        quits = state.quitCounts
        foreground = state.foreground
        names = state.names
    }

    init(start: Date, end: Date, focused: TimeInterval, planned: TimeInterval?, outcome: SessionEndReason, goal: String = "",
         blocks: [String: Int] = [:], quits: [String: Int] = [:], foreground: [String: TimeInterval] = [:],
         names: [String: String] = [:], finished: Bool? = nil) {
        self.finished = finished
        self.start = start
        self.end = end
        self.focused = focused
        self.planned = planned
        self.outcome = outcome
        self.goal = goal
        self.blocks = blocks
        self.quits = quits
        self.foreground = foreground
        self.names = names
    }

    static let minimumFocus: TimeInterval = 60
}

/// The history file. Kept to the most recent `limit` sessions.
@MainActor
final class FocusHistory {
    struct File: Codable {
        var version = 1
        var sessions: [SessionEntry]
    }

    static let limit = 5000

    let url: URL
    private(set) var sessions: [SessionEntry] = []

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) {
            sessions = file.sessions
        }
    }

    func append(_ entry: SessionEntry) {
        sessions.append(entry)
        if sessions.count > Self.limit { sessions.removeFirst(sessions.count - Self.limit) }
        save()
    }

    /// Records the answer to "did you finish?" for one session.
    @discardableResult
    func setFinished(_ id: SessionEntry.ID, _ finished: Bool) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return false }
        sessions[index].finished = finished
        save()
        return true
    }

    func clear() {
        sessions.removeAll()
        try? FileManager.default.removeItem(at: url)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Self.encode(sessions).write(to: url, options: .atomic)
    }

    /// The file's bytes. Saving and exporting both come through here, so what
    /// "Export as JSON" writes is always what the file itself holds, and
    /// stays readable by Bench and Agent Day. `pretty` only adds line breaks
    /// and sorts the keys, for a file a person may open.
    nonisolated static func encode(_ sessions: [SessionEntry], pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        return try encoder.encode(File(sessions: sessions))
    }
}

// MARK: - Export

/// The history as files other tools can open. Pure, so the tests can pin the
/// time zone and feed it awkward goals.
enum HistoryExport {
    enum Format: CaseIterable, Sendable {
        case csv, json

        var fileExtension: String { self == .csv ? "csv" : "json" }
    }

    static let csvColumns = ["start", "end", "planned_minutes", "focused_minutes", "completed",
                             "goal", "finished", "blocked_count", "most_blocked"]

    /// One row per session, oldest first as stored, under a header row.
    /// Times carry their offset (`2026-09-28T09:15:00-07:00`) so a session
    /// means the same moment wherever the file is opened. Rows end in CRLF,
    /// as RFC 4180 has it, which also keeps a newline inside a quoted goal
    /// unambiguous.
    ///
    /// `completed` is yes only when the countdown reached zero, the same
    /// sessions the Stats page counts as completed: one that ran out while
    /// Nidus was not running is no.
    static func csv(_ sessions: [SessionEntry], timeZone: TimeZone = .current) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.calendar = Calendar(identifier: .gregorian)
        stamp.timeZone = timeZone
        // xxx writes +hh:mm, never Z, so the offset is always visible.
        stamp.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"

        var lines = [csvColumns.map(field).joined(separator: ",")]
        for s in sessions {
            let cells = [
                stamp.string(from: s.start),
                stamp.string(from: s.end),
                s.planned.map(minutes) ?? "",
                minutes(s.focused),
                s.outcome == .completed ? "yes" : "no",
                s.goal,
                s.finished.map { $0 ? "yes" : "no" } ?? "",
                String(s.blocks.values.reduce(0, +)),
                mostBlocked(in: s),
            ]
            lines.append(cells.map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// The entries as the history file stores them, so what is exported can
    /// be read back by Nidus itself. Dates are the file's own, seconds since
    /// 2001; the CSV is the one with readable times.
    static func json(_ sessions: [SessionEntry]) throws -> Data {
        try FocusHistory.encode(sessions, pretty: true)
    }

    /// A field as RFC 4180 writes it: in quotes when it holds a comma, a
    /// quote or a line break, with quotes doubled. Scalars, not characters:
    /// Swift reads CR LF as one character that equals neither.
    static func field(_ value: String) -> String {
        let needsQuotes = value.unicodeScalars.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// "25", "24.5": one decimal at most, with no locale's separator.
    static func minutes(_ seconds: TimeInterval) -> String {
        let value = (seconds / 60 * 10).rounded() / 10
        return value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// The most-blocked item's display name; the first alphabetically when
    /// two tie, since a dictionary has no order of its own. Empty when
    /// nothing was blocked.
    static func mostBlocked(in entry: SessionEntry) -> String {
        entry.blocks
            .filter { $0.value > 0 }
            .map { (name: entry.names[$0.key] ?? $0.key, count: $0.value) }
            .min { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }?
            .name ?? ""
    }
}

/// Everything the Stats page shows, worked out from the sessions. Pure, so
/// the tests can pin the calendar and the day.
struct FocusStats: Equatable, Sendable {
    struct Tally: Equatable, Sendable {
        var key: String
        var name: String
        var value: Double
    }

    /// One square of the graph: a day and how long was focused on it.
    struct Day: Equatable, Sendable, Identifiable {
        var date: Date
        var focused: TimeInterval
        /// Days after today are drawn empty, not as zero.
        var isFuture: Bool
        var id: Date { date }
    }

    var sessionCount = 0
    var completedCount = 0
    var totalFocused: TimeInterval = 0
    var currentStreak = 0
    var longestStreak = 0
    var longestSession: SessionEntry?
    var mostBlocked: Tally?
    var mostQuit: Tally?
    /// The apps most in front while focusing, most first.
    var topApps: [Tally] = []
    /// Weeks of days, oldest week first; each week starts on the calendar's
    /// first weekday, so every column of the graph is one week.
    var weeks: [[Day]] = []
    var focusedThisWeek: TimeInterval = 0
    /// Sessions whose goal got an answer, and how many of those were finished.
    var goalsAnswered = 0
    var goalsFinished = 0

    var isEmpty: Bool { sessionCount == 0 }

    init() {}

    /// The streak a just-recorded session carried on, when it was the day's
    /// first and the streak is two days or more, so "day 12 in a row" is said
    /// once a day. `entry` must already be in `sessions`.
    static func streakMilestone(for entry: SessionEntry, in sessions: [SessionEntry],
                                calendar: Calendar = .current) -> Int? {
        let day = calendar.startOfDay(for: entry.start)
        let sameDay = sessions.filter { calendar.startOfDay(for: $0.start) == day }
        guard sameDay.count == 1, sameDay[0].id == entry.id else { return nil }
        let streak = FocusStats(sessions: sessions, now: entry.end, calendar: calendar, weeks: 1).currentStreak
        return streak >= 2 ? streak : nil
    }

    init(sessions: [SessionEntry], now: Date = Date(), calendar: Calendar = .current, weeks weekCount: Int = 26) {
        sessionCount = sessions.count
        completedCount = sessions.filter { $0.outcome == .completed }.count
        totalFocused = sessions.reduce(0) { $0 + $1.focused }
        longestSession = sessions.max { $0.focused < $1.focused }
        goalsAnswered = sessions.filter { $0.finished != nil }.count
        goalsFinished = sessions.filter { $0.finished == true }.count

        var byDay: [Date: TimeInterval] = [:]
        for s in sessions { byDay[calendar.startOfDay(for: s.start), default: 0] += s.focused }

        // Streaks: consecutive days with any focus. Today not yet focused
        // does not break a streak that ran to yesterday.
        let today = calendar.startOfDay(for: now)
        let focusedDays = Set(byDay.filter { $0.value > 0 }.keys)
        var day = focusedDays.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        while focusedDays.contains(day) {
            currentStreak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        var run = 0
        var previous: Date?
        for d in focusedDays.sorted() {
            if let p = previous, calendar.date(byAdding: .day, value: 1, to: p) == d { run += 1 } else { run = 1 }
            longestStreak = max(longestStreak, run)
            previous = d
        }

        func top(_ pick: (SessionEntry) -> [String: Double]) -> [Tally] {
            var sums: [String: Double] = [:]
            var names: [String: String] = [:]
            for s in sessions {
                for (k, v) in pick(s) {
                    sums[k, default: 0] += v
                    if let n = s.names[k] { names[k] = n }
                }
            }
            return sums.map { Tally(key: $0.key, name: names[$0.key] ?? $0.key, value: $0.value) }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.name < $1.name }
        }
        mostBlocked = top { $0.blocks.mapValues(Double.init) }.first
        mostQuit = top { $0.quits.mapValues(Double.init) }.first
        topApps = Array(top { $0.foreground }.prefix(3))

        // The graph: `weekCount` columns ending with the week that holds today.
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let first = calendar.date(byAdding: .weekOfYear, value: -(weekCount - 1), to: weekStart)!
        weeks = (0..<weekCount).map { w in
            (0..<7).map { d in
                let date = calendar.date(byAdding: .day, value: w * 7 + d, to: first)!
                return Day(date: date, focused: byDay[date] ?? 0, isFuture: date > today)
            }
        }
        focusedThisWeek = weeks.last?.reduce(0) { $0 + $1.focused } ?? 0
    }

    /// The graph's shade for a day, 0 (none) to 4, on fixed thresholds so a
    /// square means the same thing from month to month.
    static func level(for focused: TimeInterval) -> Int {
        switch focused {
        case ..<60: return 0
        case ..<(25 * 60): return 1
        case ..<(60 * 60): return 2
        case ..<(2 * 60 * 60): return 3
        default: return 4
        }
    }
}
