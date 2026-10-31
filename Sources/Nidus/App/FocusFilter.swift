//
//  FocusFilter.swift
//  Nidus
//
//  A Focus filter: in System Settings > Focus > (a Focus) > Focus Filters the
//  user adds Nidus and picks a setup. Turning that macOS Focus on starts the
//  setup; turning it off ends the session the filter started, and only that
//  one. The system calls the same intent both times: on with the setup that
//  was configured, off with the parameters back at their defaults (no setup),
//  so no setup means off.
//
//  It goes through the same guarded start as the Shortcuts actions
//  (FocusOutside.swift), so it answers to the rules of a nidus:// link, strict
//  mode first. Nothing is replaced: if a session or a break is already on,
//  turning the Focus on does nothing. That is also what makes a loop safe. A
//  setup whose start Shortcut turns on a Focus whose filter starts the same
//  setup meets a session that is already running, and stops there.
//
//  What the filter started is remembered as the session's start time, in
//  UserDefaults, so it survives Nidus quitting and opening again mid-session.
//  Turning the Focus off ends the session only if it is still that session
//  and not strict. A strict session, one you started yourself, or one a
//  later activation started is left alone. The key is cleared whenever it no
//  longer matches. Like any Shortcut or JSON start, this start never raises
//  the browser permission prompt: nobody may be at the screen.
//
//  The intent shows up in Focus settings only if Scripts/appintents-metadata.sh
//  has put Metadata.appintents into the app bundle (see FocusIntents.swift).
//

import AppIntents
import Foundation

// MARK: - Decisions

/// What the Focus turning on or off should do, apart from doing it.
enum FocusFilterDecision {
    enum Activation: Equatable, Sendable { case start, ignore }
    enum Deactivation: Equatable, Sendable { case end, leave }

    /// Start only into silence. Anything already on, a break included, stays.
    static func onActivate(sessionRunning: Bool, onBreak: Bool) -> Activation {
        sessionRunning || onBreak ? .ignore : .start
    }

    /// End only the session the filter started: the same start time as the
    /// one remembered, and not strict.
    static func onDeactivate(currentStartedAt: Date?, currentStrict: Bool, storedStartedAt: Date?) -> Deactivation {
        guard let currentStartedAt, let storedStartedAt, !currentStrict,
              currentStartedAt.timeIntervalSinceReferenceDate == storedStartedAt.timeIntervalSinceReferenceDate
        else { return .leave }
        return .end
    }
}

// MARK: - The remembered start

/// The start time of the session the Focus filter started, if one is running.
/// Stored as seconds so a Date comes back exactly as it went in.
struct FocusFilterMarker {
    static let key = "local.sam.nidus.focusFilter.startedAt"

    var defaults: UserDefaults = .standard

    var startedAt: Date? {
        get { (defaults.object(forKey: Self.key) as? Double).map(Date.init(timeIntervalSinceReferenceDate:)) }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.timeIntervalSinceReferenceDate, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }
}

// MARK: - Doing it

/// A model the filter can drive: the commands any outside start uses, and
/// when the session began.
@MainActor
protocol FocusFilterTarget: FocusCommandTarget {
    var sessionStartedAt: Date? { get }
}

extension NidusModel: FocusFilterTarget {
    var sessionStartedAt: Date? { engine?.session?.startedAt }
}

/// What the filter did, for the tests and the log; the system shows nothing.
enum FocusFilterOutcome: Equatable, Sendable {
    case started
    /// Something was already on; nothing changed.
    case keptWhatWasOn
    case ended
    /// Off, and the session isn't the filter's (or is strict): left running.
    case leftRunning
    /// Off, and nothing of the filter's was running.
    case nothingToEnd
}

@MainActor
enum FocusFilter {
    /// The Focus turned on with this setup.
    @discardableResult
    static func activate(setupID: String, on target: some FocusFilterTarget,
                         marker: FocusFilterMarker = FocusFilterMarker()) throws -> FocusFilterOutcome {
        let status = target.commandStatus
        guard FocusFilterDecision.onActivate(sessionRunning: status.isOn, onBreak: status.state == .onBreak) == .start else {
            // Not ours to keep a note of, unless it is the very session we started.
            if marker.startedAt != target.sessionStartedAt { marker.startedAt = nil }
            return .keptWhatWasOn
        }
        let resolved: (request: SessionRequest, setup: FocusSetup?, unmatched: [String])
        switch target.outsideRequest(NidusLink.Start(preset: setupID)) {
        case .success(let found): resolved = found
        case .failure(.noMatchingCategory): throw FocusIntentError.categoryNotFound
        case .failure: throw FocusIntentError.setupNotFound
        }
        var request = resolved.request
        request.asksBrowserAccess = false
        switch target.startFromOutside(request) {
        case .started:
            marker.startedAt = target.sessionStartedAt
            return .started
        case .busy:
            return .keptWhatWasOn
        case .nothingToBlock: throw FocusIntentError.nothingToBlock
        case .notReady: throw FocusIntentError.notReady
        }
    }

    /// The Focus turned off.
    @discardableResult
    static func deactivate(on target: some FocusFilterTarget,
                           marker: FocusFilterMarker = FocusFilterMarker()) -> FocusFilterOutcome {
        let stored = marker.startedAt
        defer { marker.startedAt = nil }
        guard stored != nil else { return .nothingToEnd }
        let decision = FocusFilterDecision.onDeactivate(
            currentStartedAt: target.sessionStartedAt, currentStrict: target.commandStatus.isStrict,
            storedStartedAt: stored)
        guard decision == .end else { return .leftRunning }
        target.endFromOutside()
        return .ended
    }
}

// MARK: - The filter

/// "Nidus" in a Focus's filters: the setup to start while that Focus is on.
struct FocusFilterIntent: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Start a Nidus setup"
    static let description = IntentDescription(
        "Starts a Nidus setup while this Focus is on, and ends it when the Focus turns off. Nothing changes if a session or a break is already on, and a strict session is never ended.")

    @Parameter(title: "Setup", description: "The setup to start while this Focus is on.")
    var setup: FocusSetupEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$setup)")
    }

    var displayRepresentation: DisplayRepresentation {
        if let setup { return DisplayRepresentation(title: "Start \(setup.name)") }
        return DisplayRepresentation(title: "Nidus")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await NidusModel.forIntent()
        if let setup {
            try FocusFilter.activate(setupID: setup.id, on: model)
        } else {
            FocusFilter.deactivate(on: model)
        }
        return .result()
    }
}
