//
//  FocusSchedule.swift
//  Nidus
//
//  A weekly schedule ("weekdays 9:00 to 12:00, Social and Messaging blocked,
//  goal Deep work") and the rules for when it starts a session. Everything
//  here is a pure function of a date, a calendar and the schedules, so the
//  clock changes, missed starts and overlaps are tested without a clock or a
//  timer. The scheduler that runs them is FocusScheduler.
//
//  No UI and no timers: this file also compiles into the tests.
//

import Foundation

/// A time on the clock, to the minute. A schedule's start and end are these,
/// not dates, so "9:00" stays 9:00 across a clock change.
struct ScheduleTime: Codable, Hashable, Comparable, Sendable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int = 0) {
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
    }

    init(minutesIntoDay total: Int) {
        let total = min(23 * 60 + 59, max(0, total))
        self.init(hour: total / 60, minute: total % 60)
    }

    var minutesIntoDay: Int { hour * 60 + minute }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.minutesIntoDay < rhs.minutesIntoDay }
}

struct FocusSchedule: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var isOn: Bool
    /// `Calendar` weekday numbers: 1 is Sunday, 7 is Saturday.
    var weekdays: Set<Int>
    var start: ScheduleTime
    /// After `start`, on the same day: a schedule never runs past midnight.
    var end: ScheduleTime
    /// FocusCategory ids.
    var categoryIDs: [String]
    var mode: SessionPlan.Mode
    var strict: Bool
    /// Empty for none.
    var goal: String

    static let workweek: Set<Int> = [2, 3, 4, 5, 6]
    static let weekend: Set<Int> = [1, 7]
    static let everyDay: Set<Int> = Set(1...7)

    init(id: String = UUID().uuidString, isOn: Bool = true, weekdays: Set<Int> = FocusSchedule.workweek,
         start: ScheduleTime = ScheduleTime(hour: 9), end: ScheduleTime = ScheduleTime(hour: 12),
         categoryIDs: [String] = [], mode: SessionPlan.Mode = .block, strict: Bool = false, goal: String = "") {
        self.id = id
        self.isOn = isOn
        self.weekdays = weekdays
        self.start = start
        self.end = end
        self.categoryIDs = categoryIDs
        self.mode = mode
        self.strict = strict
        self.goal = goal
    }

    /// Moves the start and keeps the length, as Calendar does, unless the day
    /// runs out first; then the end stops at 11:59 PM.
    mutating func setStart(_ time: ScheduleTime) {
        let length = max(1, end.minutesIntoDay - start.minutesIntoDay)
        let latestStart = ScheduleTime(hour: 23, minute: 58)
        start = min(time, latestStart)
        end = ScheduleTime(minutesIntoDay: start.minutesIntoDay + length)
    }

    /// The end must be after the start; an earlier one is held to a minute
    /// past it.
    mutating func setEnd(_ time: ScheduleTime) {
        end = max(time, ScheduleTime(minutesIntoDay: start.minutesIntoDay + 1))
    }

    private enum CodingKeys: String, CodingKey {
        case id, isOn, weekdays, start, end, categoryIDs, mode, strict, goal
    }

    /// Every field but the id may be missing, so a later version that adds a
    /// field does not make this one drop the whole list: a list that fails to
    /// decode reads as empty, and the next save would erase it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            isOn: try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? true,
            weekdays: try c.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? Self.workweek,
            start: try c.decodeIfPresent(ScheduleTime.self, forKey: .start) ?? ScheduleTime(hour: 9),
            end: try c.decodeIfPresent(ScheduleTime.self, forKey: .end) ?? ScheduleTime(hour: 12),
            categoryIDs: try c.decodeIfPresent([String].self, forKey: .categoryIDs) ?? [],
            mode: (try? c.decodeIfPresent(SessionPlan.Mode.self, forKey: .mode)) ?? .block,
            strict: try c.decodeIfPresent(Bool.self, forKey: .strict) ?? false,
            goal: try c.decodeIfPresent(String.self, forKey: .goal) ?? ""
        )
    }
}

// MARK: - When it runs

extension FocusSchedule {
    /// One run of a schedule on one day.
    struct Occurrence: Equatable, Sendable, Identifiable {
        let schedule: FocusSchedule
        let start: Date
        let end: Date

        /// Stable for the occurrence, so a card or a log can name it.
        var id: String { "\(schedule.id)@\(Int(start.timeIntervalSince1970))" }
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// How long before a start the heads-up card shows.
    static let headsUpLead: TimeInterval = 60
    /// A start this close to its time counts as on time; the Mac was awake.
    static let onTimeGrace: TimeInterval = 2 * 60
    /// A start that was missed is made up only with at least this much of the
    /// window left; a session of a few minutes is only an interruption.
    static let missedStartMinimum: TimeInterval = 5 * 60

    /// This schedule on the calendar day containing `day`: nil when it is off,
    /// does not run that weekday, or the day's clock change leaves it no time.
    ///
    /// A time that does not exist that day (2:30 when the clocks skip from 2:00
    /// to 3:00) is read as the time it would have been had they not, 3:30, so a
    /// window that ends in the gap is still as long as it says. A time that
    /// happens twice is the first. Both ends are resolved the same way.
    func occurrence(onDayOf day: Date, calendar: Calendar) -> Occurrence? {
        guard isOn, weekdays.contains(calendar.component(.weekday, from: day)) else { return nil }
        let date = calendar.dateComponents([.year, .month, .day], from: day)
        func resolve(_ time: ScheduleTime) -> Date? {
            var parts = date
            parts.hour = time.hour
            parts.minute = time.minute
            guard let resolved = calendar.date(from: parts), calendar.isDate(resolved, inSameDayAs: day) else { return nil }
            return resolved
        }
        guard let start = resolve(start), let end = resolve(end), start < end else { return nil }
        return Occurrence(schedule: self, start: start, end: end)
    }

    /// The earliest start strictly after `date`, over the schedules that are
    /// on; nil when none will ever run. A schedule that starts at `date`
    /// itself is already running, so it is in `inProgress`, not here.
    static func nextStart(after date: Date, schedules: [FocusSchedule], calendar: Calendar) -> Occurrence? {
        let today = calendar.startOfDay(for: date)
        var best: Occurrence?
        for schedule in schedules where schedule.isOn && !schedule.weekdays.isEmpty {
            // Eight days reach this weekday next week when today's start has gone.
            for offset in 0...8 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                      let next = schedule.occurrence(onDayOf: day, calendar: calendar),
                      next.start > date else { continue }
                if best == nil || next.start < best!.start { best = next }
                break
            }
        }
        return best
    }

    /// Runs whose window holds `date`, the earliest start first, then in list
    /// order. A run that starts exactly at `date` is in progress.
    static func inProgress(at date: Date, schedules: [FocusSchedule], calendar: Calendar) -> [Occurrence] {
        schedules
            .compactMap { $0.occurrence(onDayOf: date, calendar: calendar) }
            .filter { $0.start <= date && date < $0.end }
            .enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
    }

    /// Whole minutes from `now` to `end`, for a session that ends then; nil
    /// when under a minute is left, since a length of 0 means open-ended.
    /// A partial minute is dropped, so a session never outlasts `end`, except
    /// by the slack: a start a moment after its time (a timer is never exact)
    /// still ends at the window's end rather than a minute short. A meeting
    /// passes no slack: nothing may run into it.
    static func minutes(until end: Date, from now: Date, slack: TimeInterval = 10) -> Int? {
        let minutes = Int((end.timeIntervalSince(now) + slack) / 60)
        return minutes >= 1 ? minutes : nil
    }

    enum SkipReason: String, Equatable, Sendable {
        /// Missed, with too little of the window left.
        case tooLate
        /// A session or a break was already on.
        case sessionOn
        /// A block list with nothing in it, so there is nothing to start.
        case nothingToBlock
    }

    enum Decision: Equatable, Sendable {
        /// Start a session of this many minutes, ending at the window's end.
        /// `missed` is set when the start time had passed.
        case start(minutes: Int, missed: Bool)
        case skip(SkipReason)
    }

    /// What to do with a run found in progress. On time, it starts. Late
    /// (the Mac was asleep, or Nidus was not running), it starts only with at
    /// least five minutes of the window left.
    static func decide(_ occurrence: Occurrence, now: Date) -> Decision {
        let late = now.timeIntervalSince(occurrence.start)
        let left = occurrence.end.timeIntervalSince(now)
        let missed = late > onTimeGrace
        guard left > 0, !missed || left >= missedStartMinimum,
              let minutes = minutes(until: occurrence.end, from: now) else { return .skip(.tooLate) }
        return .start(minutes: minutes, missed: missed)
    }

    /// Whether `other` (an earlier copy) differs in when it runs, rather than
    /// in what it blocks or its goal.
    func changesTiming(from other: FocusSchedule) -> Bool {
        isOn != other.isOn || weekdays != other.weekdays || start != other.start || end != other.end
    }

    /// Whether a run has been dealt with: started, skipped, or passed over. The
    /// record is the start of the last such run, per schedule, so a session
    /// the user ended early is not started again by a wake or a relaunch
    /// inside the same window.
    static func isHandled(_ occurrence: Occurrence, in handled: [String: Date]) -> Bool {
        handled[occurrence.schedule.id].map { occurrence.start <= $0 } ?? false
    }
}

// MARK: - Saying it

extension FocusSchedule {
    /// "Weekdays", "Every day", or the days named from the week's first.
    func daysSummary(calendar: Calendar) -> String {
        switch weekdays {
        case Self.everyDay: return "Every day"
        case Self.workweek: return "Weekdays"
        case Self.weekend: return "Weekends"
        case []: return "No days"
        default:
            let first = calendar.firstWeekday
            let ordered = (0..<7).map { (first - 1 + $0) % 7 + 1 }.filter(weekdays.contains)
            return ordered.map { calendar.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
        }
    }

    /// "9:00 AM to 12:00 PM", in the calendar's locale.
    func timeSummary(calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let reference = ScheduleTime.referenceDay(calendar: calendar)
        return "\(formatter.string(from: start.date(on: reference, calendar: calendar))) to \(formatter.string(from: end.date(on: reference, calendar: calendar)))"
    }

    /// What it blocks, as the popover says it: "Social, Messaging", or a count
    /// once the names stop fitting. An allow list says what it lets through.
    func categorySummary(categories: [FocusCategory]) -> String {
        let names = categoryIDs.compactMap { id in categories.first { $0.id == id }?.name }
        let list: String
        switch names.count {
        case 0: list = ""
        case 1, 2: list = names.joined(separator: ", ")
        default: list = "\(names.count) categories"
        }
        switch mode {
        case .block: return names.isEmpty ? "Nothing to block" : list
        case .allow: return names.isEmpty ? "Nothing allowed" : "Only \(list) allowed"
        }
    }

    /// "Weekdays, 9:00 AM to 12:00 PM · Social, Messaging".
    func summary(categories: [FocusCategory], calendar: Calendar) -> String {
        "\(daysSummary(calendar: calendar)), \(timeSummary(calendar: calendar)) · \(categorySummary(categories: categories))"
    }
}

extension ScheduleTime {
    /// A day with no clock change in it, in any zone that has them in the
    /// spring or autumn, for a time picker to show a time of day on.
    static func referenceDay(calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: 12)) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    func date(on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    init(_ date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }
}
