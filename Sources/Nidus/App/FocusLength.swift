//
//  FocusLength.swift
//  Nidus
//
//  A session's length as the popover handles it: the saved default
//  (`durationMinutes`), the "Custom…" field's draft, and a one-off "until"
//  time. What the Length button says, what the Length menu lists and how
//  many minutes the next Start uses are worked out here, as pure functions
//  the tests can call, with the model's members as thin wrappers.
//

import Foundation

enum FocusLength {
    /// The lengths to list: the standard ones, and `current` among them when
    /// it is not one, in order and ahead of open-ended (0), which stays last.
    /// A saved length can be anything from 1 to 1440 now, and the Settings
    /// picker and the popover menu must not show a blank for it.
    static func choices(standard: [Int], including current: Int) -> [Int] {
        guard current > 0, !standard.contains(current) else { return standard }
        let timed = (standard.filter { $0 > 0 } + [current]).sorted()
        return timed + standard.filter { $0 <= 0 }
    }

    /// The "until" time while it is still ahead. One that has passed (the
    /// popover was left open, or the time was a minute away) is no longer a
    /// choice: the length falls back to the saved one rather than start a
    /// session that is over before it begins.
    static func pending(_ target: Date?, now: Date) -> Date? {
        guard let target, target > now else { return nil }
        return target
    }

    /// What the Length button says: "25 min", "Open-ended" or "Until 3:30 PM".
    static func label(durationMinutes: Int, until target: Date?, now: Date,
                      locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        if let target = pending(target, now: now) {
            return "Until " + FocusFormat.clockTime(target, locale: locale, timeZone: timeZone)
        }
        return FocusFormat.duration(minutes: durationMinutes)
    }

    /// The minutes a Start uses when it is not told: the minutes to the
    /// "until" time, worked out now so a time chosen an hour ago still ends
    /// where it said, or the saved length (0 for open-ended).
    static func startMinutes(durationMinutes: Int, until target: Date?, now: Date) -> Int {
        guard let target = pending(target, now: now) else { return durationMinutes }
        return FocusDurationParser.minutes(until: target, from: now)
    }
}

extension FocusFormat {
    /// The time of day in the reader's own style: "3:40 PM", or "15:40".
    static func clockTime(_ date: Date, locale: Locale = .autoupdatingCurrent,
                          timeZone: TimeZone = .autoupdatingCurrent) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
    }

    /// The quiet line under the goal while a session runs: "Until 3:40 PM ·
    /// blocked 2 times", "Started 2:15 PM · blocked once" for an open-ended
    /// one, and for a pause, that it is one. A pause the user chose stops the
    /// blocking, and says so; no end time is shown because it moves when the
    /// session resumes. `endsAt` is nil for an open-ended session.
    static func runningLine(paused: Bool, blocking: Bool, endsAt: Date?, startedAt: Date, blocked: Int,
                            locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        if paused { return blocking ? "Paused" : "Paused · not blocking" }
        let when = endsAt.map { "Until " + clockTime($0, locale: locale, timeZone: timeZone) }
            ?? "Started " + clockTime(startedAt, locale: locale, timeZone: timeZone)
        guard blocked > 0 else { return when }
        return when + " · " + (blocked == 1 ? "blocked once" : "blocked \(blocked) times")
    }
}

/// What is typed in the popover's "Custom…" field, and whether the last
/// Return could not read it.
struct CustomLengthDraft: Equatable {
    var text = ""
    /// Set by a Return that could not read the text, cleared by the next
    /// edit: the field is told once, then left alone while it is fixed.
    var rejected: FocusDurationParser.Failure?

    /// What the line under the field says.
    enum Caption: Equatable {
        /// How to write a length, until there is one to show.
        case hint(String)
        /// What the text means, as it would be set.
        case preview(String)
        /// Why it was not taken.
        case problem(String)
    }

    static let example = "Try \u{201C}40\u{201D}, \u{201C}1h30\u{201D} or \u{201C}until 3:30\u{201D}"

    func caption(now: Date = Date(), calendar: Calendar = .current,
                 locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> Caption {
        if let hint = rejected?.hint { return .problem(hint) }
        switch FocusDurationParser.parse(text, now: now, calendar: calendar) {
        case .success(.minutes(let minutes)):
            return .preview(FocusFormat.duration(minutes: minutes))
        case .success(.until(let target)):
            return .preview("Until " + FocusFormat.clockTime(target, locale: locale, timeZone: timeZone))
        // Half typed ("1h", "unt") or nothing yet: no scolding while writing.
        case .failure:
            return .hint(Self.example)
        }
    }
}

// MARK: - The model's side

extension NidusModel {
    /// The one-off "until" time, if it is still ahead.
    func pendingUntil(now: Date = Date()) -> Date? {
        FocusLength.pending(untilTarget, now: now)
    }

    /// The minutes a Start with no length of its own uses.
    func minutesForNextStart(now: Date = Date()) -> Int {
        FocusLength.startMinutes(durationMinutes: durationMinutes, until: untilTarget, now: now)
    }

    /// What the popover's Length button says. (The menu bar's right-click
    /// Start subtitle should say it too: that Start uses `untilTarget` as
    /// well, so a subtitle built from `durationMinutes` alone can say
    /// "25 min" for a session that will end at 3:30.)
    var lengthLabel: String {
        FocusLength.label(durationMinutes: durationMinutes, until: untilTarget, now: Date())
    }

    /// The lengths for a picker: the standard ones, and the saved one if it
    /// is not among them.
    var durationChoicesIncludingCurrent: [Int] {
        FocusLength.choices(standard: Self.durationChoices, including: durationMinutes)
    }

    func openCustomLength() {
        customLengthDraft = CustomLengthDraft()
    }

    func cancelCustomLength() {
        customLengthDraft = nil
    }

    /// Return in the custom field: reads it and, if it reads, makes it the
    /// length and closes the field. Minutes become the saved length; a time
    /// of day is held for the next Start only. Nothing typed closes the field
    /// and keeps the length as it was. Text that cannot be read stays, with
    /// a gentle line under it, and this returns false.
    @discardableResult
    func commitCustomLength(now: Date = Date()) -> Bool {
        guard let draft = customLengthDraft else { return true }
        switch FocusDurationParser.parse(draft.text, now: now) {
        case .success(.minutes(let minutes)):
            // Choosing any saved length drops a pending "until" time.
            durationMinutes = minutes
        case .success(.until(let target)):
            untilTarget = target
        case .failure(.empty):
            break
        case .failure(let failure):
            customLengthDraft?.rejected = failure
            return false
        }
        customLengthDraft = nil
        return true
    }
}
