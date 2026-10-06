//
//  FocusOutside.swift
//  Nidus
//
//  Starting, ending and asking about focus from outside the popover: what a
//  nidus:// link and a Shortcuts action share, so the two cannot disagree
//  about strict mode. Each command says how it came out; the caller decides
//  how to say so (a link stays quiet, a Shortcut fails with a message).
//

import Foundation

// MARK: - Outcomes

/// How asking to start a session came out.
enum OutsideStart: Equatable, Sendable {
    case started
    /// A session or a break is already on.
    case busy
    /// Block mode, and every chosen category is empty.
    case nothingToBlock
    /// Nidus is still launching.
    case notReady
}

/// What ending a session from outside does. A strict session is never ended
/// this way (it ends from the menu bar, behind its phrase), or a link or a
/// Shortcut would make strict mode pointless.
enum OutsideEnd: Equatable, Sendable {
    case endsSession
    case refusesStrict
    /// On a break: stop here, with no session after it.
    case endsBreak
    case nothingRunning

    init(isActive: Bool, isStrict: Bool, isOnBreak: Bool) {
        if isActive {
            self = isStrict ? .refusesStrict : .endsSession
        } else if isOnBreak {
            self = .endsBreak
        } else {
            self = .nothingRunning
        }
    }
}

/// What the toggle did: it ends a running session, or starts the last one
/// again (or the next one, from a break).
enum OutsideToggle: Equatable, Sendable {
    case started
    case ended
    case refusedStrict
    /// Nothing was running and nothing started: no apps or websites to block.
    case couldNotStart

    init(wasActive: Bool, wasStrict: Bool, isActive: Bool) {
        if wasActive {
            self = wasStrict ? .refusedStrict : .ended
        } else {
            self = isActive ? .started : .couldNotStart
        }
    }
}

/// Where things stand, for Get Focus Status and the JSON command: read at
/// one moment (`observedAt`), and never a command acknowledgment on its own.
struct FocusStatus: Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case idle, running, paused
        case onBreak = "break"
    }

    var state: State
    /// A session with no end time. False when nothing is on, or on a break.
    var isOpenEnded: Bool
    var isStrict: Bool
    /// Apps and websites are being blocked right now: a running session, or
    /// one whose clock stopped only because the Mac is locked or asleep. A
    /// pause you chose blocks nothing.
    var isBlocking: Bool
    /// Seconds left of a timed session, or of the break. nil when idle or
    /// open-ended.
    var secondsLeft: Int?
    /// Running browsers Nidus has not been allowed to control, by name: their
    /// websites aren't blocked, however long the clock runs.
    var browsersNeedingAccess: [String] = []
    var observedAt: Date

    init(state: State, isOpenEnded: Bool = false, isStrict: Bool = false, isBlocking: Bool = false,
         remaining: TimeInterval? = nil, browsersNeedingAccess: [String] = [], observedAt: Date = Date()) {
        self.state = state
        self.isOpenEnded = state == .running || state == .paused ? isOpenEnded : false
        self.isStrict = state == .running || state == .paused ? isStrict : false
        self.isBlocking = isBlocking
        let timed = (state == .running || state == .paused) && !isOpenEnded || state == .onBreak
        secondsLeft = timed ? remaining.map { Int(max(0, $0).rounded(.up)) } : nil
        self.browsersNeedingAccess = browsersNeedingAccess
        self.observedAt = observedAt
    }

    /// A session is on, running or paused. (What 0.2.0's "Session on" meant,
    /// kept for shortcuts built on it.)
    var isOn: Bool { state == .running || state == .paused }

    /// Whole minutes, rounded up as the cards do: of the session, or of the
    /// break.
    var minutesLeft: Int? { secondsLeft.map { ($0 + 59) / 60 } }

    /// The session's minutes only: nil on a break, as 0.2.0's "Minutes left"
    /// was, so a shortcut testing it doesn't read a break as focus.
    var sessionMinutesLeft: Int? { state == .onBreak ? nil : minutesLeft }

    /// When the session or break ends, if its clock is running.
    var endsAt: Date? {
        guard state == .running || state == .onBreak, let secondsLeft else { return nil }
        return observedAt.addingTimeInterval(TimeInterval(secondsLeft))
    }

    /// For Siri, the result bubble and an assistant to repeat.
    var sentence: String {
        let left = minutesLeft.map { ", \(FocusFormat.minutes($0)) left" } ?? ""
        switch state {
        case .idle:
            return "Focus is off."
        case .running:
            return isOpenEnded ? "Focus is on, open-ended." : "Focus is on\(left)."
        case .paused:
            // Locked or asleep: the clock waits, the blocking doesn't.
            return isBlocking ? "Focus is paused while your Mac is locked\(left). Blocking stays on."
                              : "Focus is paused\(left)."
        case .onBreak:
            return "On a break\(left)."
        }
    }
}

/// What adding time from outside did.
enum OutsideAddTime: Equatable, Sendable {
    /// The minutes actually added: fewer than asked when a session would
    /// pass its 24-hour limit.
    case added(minutes: Int)
    /// Already at the limit; nothing added.
    case atMaximum
    /// An open-ended session has no end to move.
    case openEnded
    case onBreak
    case nothingRunning
    /// Minutes must be from 1 to 1440.
    case invalidMinutes

    static let minutesRange = 1...1440
}

/// Why a start asked for from outside was not even tried.
enum OutsideStartProblem: Error, Equatable, Sendable {
    /// No setup by that id or name.
    case setupNotFound
    /// More than one setup has that name; use its id.
    case setupAmbiguous
    /// Categories were named, and none of them is one of yours.
    case noMatchingCategory
}

// MARK: - Commands

/// What automation asks of Nidus: Shortcuts actions, nidus:// links and the
/// JSON command all go through this, so they keep the same rules. NidusModel
/// is the real one; tests use a fake, so no session blocks anything.
@MainActor
protocol FocusCommandTarget: AnyObject {
    var commandStatus: FocusStatus { get }
    var setups: [FocusSetup] { get }
    var categories: [FocusCategory] { get }
    func startFromOutside(_ request: SessionRequest) -> OutsideStart
    @discardableResult func endFromOutside() -> OutsideEnd
    /// Adds time the engine's way: running or paused, up to its limit.
    func extendSession(by seconds: TimeInterval)
}

extension FocusCommandTarget {
    /// Adds whole minutes to a timed session and says what happened, from
    /// the time left before and after: only a timed session has an end to
    /// move, and the engine stops at 24 hours left.
    func addTimeFromOutside(minutes: Int) -> OutsideAddTime {
        guard OutsideAddTime.minutesRange.contains(minutes) else { return .invalidMinutes }
        let before = commandStatus
        switch before.state {
        case .idle: return .nothingRunning
        case .onBreak: return .onBreak
        case .running, .paused: break
        }
        guard !before.isOpenEnded, let left = before.secondsLeft else { return .openEnded }
        // Whole minutes only, as many as the engine's 24-hour limit has
        // room for, so what's reported is exactly what was added.
        let fits = min(minutes, (Int(SessionPlan.maximumDuration) - left) / 60)
        guard fits > 0 else { return .atMaximum }
        extendSession(by: TimeInterval(fits * 60))
        return .added(minutes: fits)
    }

    /// A start from outside: a saved setup's choices first, then what was
    /// asked for over them. Strict only ever turns on: a link, a Shortcut or
    /// an assistant can't make a session weaker than the setup or Settings
    /// would. Nothing named that doesn't exist is quietly swapped for the
    /// popover's choices.
    func outsideRequest(_ start: NidusLink.Start) -> Result<(request: SessionRequest, setup: FocusSetup?, unmatched: [String]), OutsideStartProblem> {
        var setup: FocusSetup?
        if let key = start.preset {
            switch FocusSetup.find(key, in: setups) {
            case .found(let found): setup = found
            case .notFound: return .failure(.setupNotFound)
            case .ambiguous: return .failure(.setupAmbiguous)
            }
        }
        guard case .success(let resolved) = start.resolve(against: categories) else {
            return .failure(.noMatchingCategory)
        }
        var request = setup?.request(categories: categories) ?? SessionRequest(goal: "")
        // An empty goal is no goal: it doesn't wipe the setup's.
        if let goal = start.goal, !goal.isEmpty { request.goal = goal }
        if let minutes = start.minutes { request.minutes = minutes }
        if start.categories != nil { request.categoryIDs = resolved.request.categoryIDs }
        if let mode = start.mode { request.mode = mode }
        if start.strict == true { request.strict = true }
        return .success((request, setup, resolved.unmatched))
    }
}

extension NidusModel: FocusCommandTarget {
    func extendSession(by seconds: TimeInterval) { controller?.extend(by: seconds) }

    var commandStatus: FocusStatus {
        let state: FocusStatus.State = isActive ? (isPaused ? .paused : .running) : isOnBreak ? .onBreak : .idle
        let needing = isActive ? BrowserProfile.known.filter { browser in
            guard let error = controller?.browserAccess[browser.bundleID] else { return false }
            return error == .notPermitted || error == .needsConsent
        }.map(\.name) : []
        return FocusStatus(state: state, isOpenEnded: isOpenEnded, isStrict: isStrict,
                           isBlocking: engine?.enforcement != nil,
                           remaining: state == .onBreak ? breakRemaining : remaining,
                           browsersNeedingAccess: needing)
    }
}

extension NidusModel {
    /// The model of the app that is running, for Shortcuts actions. They run
    /// in this process, but the system makes their types itself, so they
    /// cannot be handed the model; the app delegate sets this once the model
    /// is ready, and a demo or render run leaves it nil so a Shortcut can
    /// only ever reach the real app.
    @MainActor static weak var running: NidusModel?

    /// The running model, waiting up to `timeout` for a launch that a
    /// Shortcut itself started to finish; nil if it does not.
    @MainActor static func waitUntilRunning(timeout: Duration = .seconds(5)) async -> NidusModel? {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let model = running, model.controller != nil { return model }
            guard ContinuousClock.now < deadline, (try? await Task.sleep(for: .milliseconds(100))) != nil else { return nil }
        }
    }

    /// `startSession(_:)` with the reason it said no.
    func startFromOutside(_ request: SessionRequest) -> OutsideStart {
        if startSession(request) { return .started }
        guard controller != nil else { return .notReady }
        return isActive || isOnBreak ? .busy : .nothingToBlock
    }

    /// Ends what is running, unless it is strict: that gets the strict card
    /// and keeps going.
    @discardableResult
    func endFromOutside() -> OutsideEnd {
        let outcome = OutsideEnd(isActive: isActive, isStrict: isStrict, isOnBreak: isOnBreak)
        switch outcome {
        case .endsSession: endSession()
        case .refusesStrict: presentStrictHUD()
        case .endsBreak: endBreak()
        case .nothingRunning: break
        }
        return outcome
    }

    /// The keyboard shortcut's command (`toggleSession`), saying what it did.
    @discardableResult
    func toggleFromOutside() -> OutsideToggle {
        let wasActive = isActive, wasStrict = isStrict
        toggleSession()
        return OutsideToggle(wasActive: wasActive, wasStrict: wasStrict, isActive: isActive)
    }

}
