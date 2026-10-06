//
//  FocusDurationParser.swift
//  Nidus
//
//  Reads what is typed into the popover's "Custom…" length field: a number
//  of minutes ("40", "1h30", "1:30") or a time of day to work until
//  ("until 3:30pm"). Pure: the clock and the calendar are passed in, so the
//  tests pin both.
//
//  No UI import: this file also compiles into the tests.
//

import Foundation

/// What a custom length means once it is read.
enum FocusDurationInput: Equatable, Sendable {
    /// A length, 1 to 1440. It can be kept as the default length.
    case minutes(Int)
    /// A moment to work until. It is held for the next Start only, and
    /// turned into minutes then: a saved "until 3:30" would be wrong tomorrow.
    case until(Date)
}

enum FocusDurationParser {
    /// A session is at least a minute and, like `SessionPlan.maximumDuration`,
    /// at most a day.
    static let minutesRange = 1...1440

    enum Failure: Error, Equatable, Sendable {
        /// Nothing typed. Not an error to show: it leaves the length as it was.
        case empty
        /// Not a length or a time of day Nidus knows how to read.
        case unreadable
        /// Read, but under a minute or over a day (or an hour of the day
        /// that does not exist, such as 13pm, which is `unreadable`).
        case outOfRange

        /// A gentle line for the field, or nil where there is nothing to say.
        var hint: String? {
            switch self {
            case .empty: return nil
            case .unreadable: return "Couldn\u{2019}t read that. Try \u{201C}40\u{201D}, \u{201C}1h30\u{201D} or \u{201C}until 3:30\u{201D}."
            case .outOfRange: return "Pick between 1 minute and 24 hours."
            }
        }
    }

    /// Reads a length or a time of day. Accepted, in any case and spacing:
    ///
    /// - Minutes: `40`, `40m`, `40 min`, `90 minutes`.
    /// - Hours, with or without minutes: `2h`, `1h30`, `1h30m`, `1 hr 30 min`,
    ///   `1.5 hours` (a comma works too).
    /// - Hours and minutes with a colon: `1:30` is an hour and a half, never
    ///   half past one.
    /// - A time of day to work until: `until 3:30`, `until 15:30`,
    ///   `until 3:30pm`, `until 3pm`, `until 15`. `till` works too, and so
    ///   does a time with am or pm and no `until` (`3:30pm`).
    ///
    /// A time of day is the next occurrence after `now`, so "until 3:30pm"
    /// typed at 4pm means tomorrow. Without am or pm, an hour from 1 to 12 is
    /// ambiguous, and the next occurrence of either reading is taken, which
    /// is always within 12 hours: "until 3:30" at 2pm is 3:30pm, and at 4pm
    /// is 3:30am. An hour of 0 or from 13 to 23 is a 24-hour time and means
    /// only itself. A time exactly equal to `now` is a full cycle away (12
    /// or 24 hours) rather than "now", since a session is at least a minute.
    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Result<FocusDurationInput, Failure> {
        let s = normalized(text)
        guard !s.isEmpty else { return .failure(.empty) }

        if let match = s.wholeMatch(of: /(?:until|till) ?(.+)/) {
            return clock(String(match.1), now: now, calendar: calendar)
        }
        if s.hasSuffix("am") || s.hasSuffix("pm") {
            return clock(s, now: now, calendar: calendar)
        }
        if let match = s.wholeMatch(of: /(\d{1,2}):(\d{2})/) {
            guard let hours = Int(match.1), let minutes = Int(match.2), minutes < 60 else { return .failure(.unreadable) }
            return minutesResult(hours * 60 + minutes)
        }
        if let match = s.wholeMatch(of: /(?:(\d+(?:[.,]\d+)?) ?(?:h|hr|hrs|hour|hours))? ?(?:(\d+) ?(?:m|min|mins|minute|minutes)?)?/) {
            let hoursText = match.1.map(String.init)
            let minutesText = match.2.map(String.init)
            guard hoursText != nil || minutesText != nil else { return .failure(.unreadable) }
            var total = 0.0
            if let hoursText {
                guard let hours = Double(hoursText.replacingOccurrences(of: ",", with: ".")) else { return .failure(.unreadable) }
                // "1.5h" is whole on its own; "1.5h 30" would say it twice.
                if hoursText.contains(where: { $0 == "." || $0 == "," }), minutesText != nil { return .failure(.unreadable) }
                total = hours * 60
            }
            if let minutesText {
                // More digits than an Int holds is a number, and too big.
                guard let minutes = Int(minutesText) else { return .failure(.outOfRange) }
                // "1h90" is a typo; a bare "90" is minutes.
                if hoursText != nil, minutes >= 60 { return .failure(.unreadable) }
                total += Double(minutes)
            }
            guard total < Double(Int32.max) else { return .failure(.outOfRange) }
            return minutesResult(Int(total.rounded()))
        }
        return .failure(.unreadable)
    }

    /// The whole minutes from `now` to `target`, rounded up so a session of
    /// that length ends at or just after the target (and its end reads as
    /// the target's own minute), and kept inside 1 to 1440 so a target in
    /// the past or the next day can never make an open-ended or empty
    /// session.
    static func minutes(until target: Date, from now: Date) -> Int {
        // A thousandth of a second keeps a time that is exactly N minutes
        // away from rounding up to N + 1 on floating point noise.
        let raw = ((target.timeIntervalSince(now) - 0.001) / 60).rounded(.up)
        guard raw.isFinite else { return minutesRange.upperBound }
        return min(max(Int(raw), minutesRange.lowerBound), minutesRange.upperBound)
    }

    // MARK: Private

    private static func minutesResult(_ minutes: Int) -> Result<FocusDurationInput, Failure> {
        minutesRange.contains(minutes) ? .success(.minutes(minutes)) : .failure(.outOfRange)
    }

    /// Lower case, one space between words, "a.m." as "am". macOS writes its
    /// times with a narrow no-break space before the PM; that, and any other
    /// space, counts as one.
    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .replacingOccurrences(of: "a.m.", with: "am")
            .replacingOccurrences(of: "p.m.", with: "pm")
    }

    /// "3", "3:30", "15:30", "3pm" or "3:30 pm", as the next time that
    /// happens.
    private static func clock(_ text: String, now: Date, calendar: Calendar) -> Result<FocusDurationInput, Failure> {
        guard let match = text.wholeMatch(of: /(\d{1,2})(?::(\d{2}))? ?(am|pm)?/),
              let hour = Int(match.1) else { return .failure(.unreadable) }
        let minute = match.2.flatMap { Int($0) } ?? 0
        guard minute < 60 else { return .failure(.unreadable) }

        let hours: [Int]
        if let meridiem = match.3 {
            guard (1...12).contains(hour) else { return .failure(.unreadable) }
            hours = [hour % 12 + (meridiem == "pm" ? 12 : 0)]
        } else if hour == 0 || (13...23).contains(hour) {
            hours = [hour]
        } else if (1...12).contains(hour) {
            hours = [hour % 12, hour % 12 + 12]
        } else {
            return .failure(.unreadable)
        }

        let times = hours.compactMap { next(hour: $0, minute: minute, after: now, calendar: calendar) }
        guard let soonest = times.min() else { return .failure(.unreadable) }
        return .success(.until(soonest))
    }

    /// The first moment after `date` that the clock reads `hour:minute`.
    private static func next(hour: Int, minute: Int, after date: Date, calendar: Calendar) -> Date? {
        let components = DateComponents(hour: hour, minute: minute, second: 0)
        guard let found = calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime) else { return nil }
        // `nextDate(after:)` should not return `date` itself; a session
        // that ended before it began would be worse than looking again.
        if found > date { return found }
        return calendar.nextDate(after: found, matching: components, matchingPolicy: .nextTime)
    }
}
