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

/// Whether a session is on, for Get Focus Status.
struct FocusStatus: Equatable, Sendable {
    var isOn: Bool
    /// Whole minutes, rounded up as the cards do; nil when nothing is on or
    /// the session is open-ended.
    var minutesLeft: Int?

    init(isActive: Bool, isOpenEnded: Bool, remaining: TimeInterval) {
        isOn = isActive
        minutesLeft = isActive && !isOpenEnded ? Int((max(0, remaining) / 60).rounded(.up)) : nil
    }

    /// For Siri and the result bubble.
    var sentence: String {
        guard isOn else { return "Focus is off." }
        guard let minutes = minutesLeft else { return "Focus is on, open-ended." }
        return "Focus is on, \(minutes) \(minutes == 1 ? "minute" : "minutes") left."
    }
}

// MARK: - Commands

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

    var focusStatus: FocusStatus {
        FocusStatus(isActive: isActive, isOpenEnded: isOpenEnded, remaining: remaining)
    }
}
