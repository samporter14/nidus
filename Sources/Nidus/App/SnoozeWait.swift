//
//  SnoozeWait.swift
//  Nidus
//
//  A pause before a snooze: the middle ground between normal mode, where
//  Snooze is one click, and strict mode, where there is none. When Settings
//  asks for a wait, Snooze opens a card that counts down first. This file is
//  the card's logic with no UI and no clock of its own (every question takes
//  the moment to answer for), so the tests can walk the countdown by hand.
//  The card is in FocusSurfaces.
//

import Foundation

/// One snooze that is waiting out its pause.
struct SnoozeWait: Equatable, Sendable {
    /// What the snooze lets through: a bundle identifier or a domain.
    let key: String
    /// What the card calls it: "Slack", "youtube.com".
    let name: String
    let startedAt: Date
    /// The pause, always more than zero.
    let seconds: Int

    /// What Settings offers, in seconds. 0 snoozes right away.
    static let choices = [0, 10, 30]

    /// How long the card stays once the wait is over: long enough to look
    /// back at it and press Snooze.
    static let readyWindow: TimeInterval = 10

    /// A stray value (a hand-edited preference, a choice a later version
    /// dropped) means no wait rather than a Picker with nothing selected.
    static func normalized(_ seconds: Int) -> Int {
        choices.contains(seconds) ? seconds : 0
    }

    static func choiceLabel(_ seconds: Int) -> String {
        seconds == 0 ? "Snooze right away" : "Wait \(seconds) seconds"
    }

    // MARK: Countdown

    /// A tick that lands a hair early (or a clock that steps back a hair)
    /// must still read as the second it was meant for, not one more.
    private static let tolerance: TimeInterval = 0.01

    func elapsed(at now: Date) -> TimeInterval {
        now.timeIntervalSince(startedAt)
    }

    /// Whole seconds still to wait, rounded up, so the card reads "10 sec" at
    /// the start and never "0 sec" before it is over.
    func secondsLeft(at now: Date) -> Int {
        let left = Int((Double(seconds) - elapsed(at: now) - Self.tolerance).rounded(.up))
        return min(seconds, max(0, left))
    }

    func isReady(at now: Date) -> Bool {
        secondsLeft(at: now) == 0
    }

    /// 0 to 1, how much of the wait is over, for the ring.
    func progress(at now: Date) -> Double {
        1 - Double(secondsLeft(at: now)) / Double(seconds)
    }

    /// How long the card stays up in all: the wait and the window after it.
    var cardDuration: TimeInterval {
        TimeInterval(seconds) + Self.readyWindow
    }

    /// The card has been gone a while. A new request then starts a fresh
    /// wait, so an old one cannot be used to skip the pause.
    func isLapsed(at now: Date) -> Bool {
        elapsed(at: now) > cardDuration
    }

    // MARK: Words

    var title: String { "Snooze \(name)?" }

    func detail(at now: Date) -> String {
        let left = secondsLeft(at: now)
        return left == 0 ? "Take a breath first. You can snooze now."
                         : "Take a breath first. You can snooze in \(left) sec."
    }

    /// For VoiceOver, said as the card comes up: seconds in full.
    var spokenSummary: String {
        "\(title) Take a breath first. You can snooze in \(seconds) seconds."
    }

    /// What the disabled Snooze button tells VoiceOver.
    func buttonLabel(at now: Date) -> String {
        let left = secondsLeft(at: now)
        switch left {
        case 0: return "Snooze \(name)"
        case 1: return "Snooze \(name), available in 1 second"
        default: return "Snooze \(name), available in \(left) seconds"
        }
    }

    // MARK: Deciding

    enum Decision: Equatable, Sendable {
        /// No wait is set: snooze at once, as it always was.
        case snoozeNow
        /// Show the card and count down.
        case wait(SnoozeWait)
        /// Nothing to snooze: strict, not running, or already let through.
        case refuse
    }

    /// Whether `key` is still stopped by the session: one is running, and
    /// `key` has not been let through. Anything else and a wait card has
    /// nothing to offer, so it goes. (The plan's lists are not consulted: a
    /// snooze never checked them, and the demo's sessions block nothing.)
    static func isStillBlocked(_ key: String, in session: SessionState?) -> Bool {
        guard let session, case .running = session.phase else { return false }
        return session.snoozes[key] == nil
    }

    func isStillBlocked(in session: SessionState?) -> Bool {
        Self.isStillBlocked(key, in: session)
    }

    /// What a request to snooze `key` does. A wait for the same item that is
    /// still on screen is kept as it is, start and all: asking again does
    /// not restart the countdown, and does not skip it.
    static func decide(key: String, name: String, waitSeconds: Int, session: SessionState?,
                       existing: SnoozeWait?, now: Date) -> Decision {
        guard let session, case .running = session.phase, !session.plan.strict else { return .refuse }
        let pause = normalized(waitSeconds)
        guard pause > 0 else { return .snoozeNow }
        guard session.snoozes[key] == nil else { return .refuse }
        if let existing, existing.key == key, !existing.isLapsed(at: now) { return .wait(existing) }
        return .wait(SnoozeWait(key: key, name: name, startedAt: now, seconds: pause))
    }
}
