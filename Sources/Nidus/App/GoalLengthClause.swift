//
//  GoalLengthClause.swift
//  Nidus
//
//  A length typed at the end of the goal: "Aims for 45m", "Aims for 1h30",
//  "Aims until 3", "Aims until 3:30pm". The popover reads it for the next
//  Start only, and the goal that is kept is just "Aims". The length itself
//  is read by `FocusDurationParser`, so the goal field and the Custom…
//  field agree on what a length is.
//
//  Only a trailing clause counts. "Wait for the build" and "Plan the trip
//  for two weeks" are goals, and stay as typed. Pure: the clock is passed
//  in. No UI import: this file also compiles into the tests.
//

import Foundation

struct GoalLengthClause: Equatable, Sendable {
    /// The goal without its clause, trimmed. Never empty.
    var goal: String
    /// A length in minutes, or a time of day to work until.
    var length: FocusDurationInput

    /// Splits `text` at its last " for …", " until …" or " till …" when the
    /// words after it are a length:
    ///
    /// - After `for`: a length with its unit or a colon ("45m", "1h30",
    ///   "1.5 hours", "1:30"). A bare number is not one: "Chapter for 3"
    ///   could mean a lot of things, and a wrong guess starts a session of
    ///   the wrong length.
    /// - After `until` or `till`: a time of day, as the Custom… field takes it
    ///   ("3", "3:30", "15:30", "3pm", "3:30 pm").
    ///
    /// nil, so the text is left alone, for anything else, including a clause
    /// with no goal before it ("for 45m") and a length outside 1 minute to
    /// 24 hours.
    static func split(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> GoalLengthClause? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.wholeMatch(of: /(.*\S)\s+(for|until|till)\s+(\S.*)/.ignoresCase()) else { return nil }
        let goal = String(match.1)
        let tail = String(match.3)
        switch match.2.lowercased() {
        case "for":
            guard tail.wholeMatch(of: /\d+/) == nil,
                  case .success(let length) = FocusDurationParser.parse(tail, now: now, calendar: calendar),
                  case .minutes = length else { return nil }
            return GoalLengthClause(goal: goal, length: length)
        default:
            guard case .success(let length) = FocusDurationParser.parse("until " + tail, now: now, calendar: calendar),
                  case .until = length else { return nil }
            return GoalLengthClause(goal: goal, length: length)
        }
    }

    /// The minutes a Start with this clause uses. A time of day is turned
    /// into minutes now, as the Custom… field's is at Start.
    func minutes(now: Date = Date()) -> Int {
        switch length {
        case .minutes(let minutes): return minutes
        case .until(let target): return FocusDurationParser.minutes(until: target, from: now)
        }
    }

    /// What the chip under the goal says: "45 min" or "Until 3:30 PM".
    func lengthLabel(locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        switch length {
        case .minutes(let minutes): return FocusFormat.duration(minutes: minutes)
        case .until(let target): return "Until " + FocusFormat.clockTime(target, locale: locale, timeZone: timeZone)
        }
    }
}
