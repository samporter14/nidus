//
//  FocusIntents.swift
//  Nidus
//
//  Shortcuts actions: Start Focus, Add Focus Time, End Focus, Toggle Focus,
//  Get Focus Status, and Run Nidus Command (JSON, for scripts and
//  assistants; FocusCommands.swift). Phrases are declared as App Shortcuts
//  too, which Apple doesn't offer on macOS; on a Mac the actions are in the
//  Shortcuts app, and Spotlight may list them. The actions run
//  in the menu bar app's own process and reach the model through
//  NidusModel.running (FocusOutside.swift), so they answer to the same rules
//  as a nidus:// link, strict mode first.
//
//  SwiftPM does not extract App Intents metadata the way Xcode does, so
//  Shortcuts sees these only if Scripts/appintents-metadata.sh has put
//  Metadata.appintents into the app bundle.
//

import AppIntents

// MARK: - Errors

/// What Shortcuts shows when an action cannot do what it was asked.
enum FocusIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case notReady
    case strict
    case busy
    case nothingToBlock
    case minutesOutOfRange
    case setupNotFound
    case categoryNotFound
    case addMinutesOutOfRange
    case nothingRunning
    case openEnded
    case onBreak
    case atMaximum

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Nidus is still starting. Try again in a moment."
        case .strict: "This is a strict session. End it from the menu bar."
        case .busy: "A focus session or a break is already on."
        case .nothingToBlock: "There is nothing to block. Add apps or websites to a category in Nidus."
        case .minutesOutOfRange: "Minutes must be from 0 to 1440."
        case .setupNotFound: "That setup isn't in Nidus anymore. Choose another."
        case .categoryNotFound: "Those categories aren't in Nidus anymore. Choose others."
        case .addMinutesOutOfRange: "Minutes must be from 1 to 1440."
        case .nothingRunning: "Focus isn't on, so there's nothing to add to."
        case .openEnded: "This session is open-ended, so there's no end to move."
        case .onBreak: "You're on a break, so there's no session to add to."
        case .atMaximum: "Nothing added: a session can't run more than 24 hours."
        }
    }
}

extension NidusModel {
    /// The running model, or the error that says Nidus is not up yet.
    @MainActor static func forIntent(timeout: Duration = .seconds(5)) async throws -> NidusModel {
        guard let model = await waitUntilRunning(timeout: timeout) else { throw FocusIntentError.notReady }
        return model
    }
}

// MARK: - Categories

/// A category, for the Categories field of Start Focus: the user's own, with
/// whatever they have added or renamed.
struct FocusCategoryEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Category")
    static let defaultQuery = FocusCategoryQuery()

    var id: String
    var name: String
    var symbol: String
    var summary: String

    init(_ category: FocusCategory) {
        id = category.id
        name = category.name
        symbol = category.symbol
        summary = category.summary
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(summary)", image: .init(systemName: symbol))
    }
}

struct FocusCategoryQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [FocusCategoryEntity] {
        let model = try await NidusModel.forIntent()
        return model.categories.filter { identifiers.contains($0.id) }.map(FocusCategoryEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [FocusCategoryEntity] {
        let model = try await NidusModel.forIntent()
        return model.categories.map(FocusCategoryEntity.init)
    }
}

// MARK: - Setups

/// A saved setup, for Start Focus. By id, so renaming one doesn't break a
/// shortcut; one deleted since comes back as a stand-in that Start Focus
/// refuses, rather than nothing, which would start the popover's choices.
struct FocusSetupEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Setup")
    static let defaultQuery = FocusSetupQuery()

    var id: String
    var name: String
    var symbol: String
    var summary: String

    init(_ setup: FocusSetup, categories: [FocusCategory]) {
        id = setup.id.uuidString
        name = setup.displayName
        symbol = setup.symbol
        summary = setup.planSummary(categories: categories)
    }

    init(missing id: String) {
        self.id = id
        name = "A deleted setup"
        symbol = "questionmark.circle"
        summary = "No longer in Nidus"
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(summary)", image: .init(systemName: symbol))
    }
}

struct FocusSetupQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [FocusSetupEntity] {
        let model = try await NidusModel.forIntent()
        return identifiers.map { id in
            guard case .found(let setup) = FocusSetup.find(id, in: model.setups),
                  setup.id.uuidString.caseInsensitiveCompare(id) == .orderedSame else { return FocusSetupEntity(missing: id) }
            return FocusSetupEntity(setup, categories: model.categories)
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [FocusSetupEntity] {
        let model = try await NidusModel.forIntent()
        return model.setups.map { FocusSetupEntity($0, categories: model.categories) }
    }
}

// MARK: - Status

/// What Get Focus Status hands back: Shortcuts reads its fields.
struct FocusStatusEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Focus status")

    /// Running or paused. (0.2.0's field, kept for shortcuts built on it.)
    @Property(title: "Session on")
    var isOn: Bool

    @Property(title: "State")
    var state: String

    @Property(title: "Blocking")
    var isBlocking: Bool

    @Property(title: "Open-ended")
    var isOpenEnded: Bool

    @Property(title: "Strict")
    var isStrict: Bool

    /// Of the session; empty on a break, as in 0.2.0.
    @Property(title: "Minutes left")
    var minutesLeft: Int?

    @Property(title: "Break minutes left")
    var breakMinutesLeft: Int?

    @Property(title: "Ends at")
    var endsAt: Date?

    @Property(title: "Checked at")
    var observedAt: Date

    /// The sentence as it was read. A property, so it travels with the
    /// entity to the next action in a shortcut.
    @Property(title: "Summary")
    var sentence: String

    init() {}

    init(_ status: FocusStatus) {
        isOn = status.isOn
        state = status.state.rawValue
        isBlocking = status.isBlocking
        isOpenEnded = status.isOpenEnded
        isStrict = status.isStrict
        minutesLeft = status.sessionMinutesLeft
        breakMinutesLeft = status.state == .onBreak ? status.minutesLeft : nil
        endsAt = status.endsAt
        observedAt = status.observedAt
        sentence = status.sentence
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(sentence)")
    }
}

// MARK: - Actions

struct StartFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Focus"
    static let description = IntentDescription(
        "Starts a focus session that blocks distracting apps and websites.",
        categoryName: "Focus")

    @Parameter(title: "Setup", description: "A saved setup to start. What else you fill in changes it for this session.")
    var setup: FocusSetupEntity?

    @Parameter(title: "Goal", description: "What you're working on.")
    var goal: String?

    @Parameter(title: "Minutes", description: "How long. 0 is open-ended. Your usual length if you leave it out.",
               inclusiveRange: (0, 1440))
    var minutes: Int?

    @Parameter(title: "Categories", description: "What to block. Your picks in Nidus if you leave it out.")
    var categories: [FocusCategoryEntity]?

    static var parameterSummary: some ParameterSummary {
        Summary("Start focus") {
            \.$setup
            \.$goal
            \.$minutes
            \.$categories
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await NidusModel.forIntent()
        if let minutes, !NidusLink.minutesRange.contains(minutes) { throw FocusIntentError.minutesOutOfRange }
        let ids = categories.flatMap { $0.isEmpty ? nil : $0.map(\.id) }
        let ask = NidusLink.Start(goal: goal.map(NidusLink.cleanedGoal), minutes: minutes, categories: ids,
                                  preset: setup?.id)
        let resolved: (request: SessionRequest, setup: FocusSetup?, unmatched: [String])
        switch model.outsideRequest(ask) {
        case .success(let found): resolved = found
        case .failure(.noMatchingCategory): throw FocusIntentError.categoryNotFound
        case .failure: throw FocusIntentError.setupNotFound
        }
        switch model.startFromOutside(resolved.request) {
        case .started: return .result(dialog: "\(FocusFormat.started(resolved.setup, status: model.commandStatus))")
        case .busy: throw FocusIntentError.busy
        case .nothingToBlock: throw FocusIntentError.nothingToBlock
        case .notReady: throw FocusIntentError.notReady
        }
    }
}

struct EndFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "End Focus"
    static let description = IntentDescription(
        "Ends the focus session, or the break after it. A strict session can only be ended from the menu bar.",
        categoryName: "Focus")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await NidusModel.forIntent()
        switch model.endFromOutside() {
        case .endsSession: return .result(dialog: "Focus ended.")
        case .endsBreak: return .result(dialog: "Break ended.")
        case .nothingRunning: return .result(dialog: "Focus isn't on.")
        case .refusesStrict: throw FocusIntentError.strict
        }
    }
}

struct ToggleFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Focus"
    static let description = IntentDescription(
        "Ends the focus session if one is on, or starts the last one again. Give it a key in Shortcuts for a global shortcut.",
        categoryName: "Focus")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await NidusModel.forIntent()
        switch model.toggleFromOutside() {
        case .started: return .result(dialog: "Focus started.")
        case .ended: return .result(dialog: "Focus ended.")
        case .refusedStrict: throw FocusIntentError.strict
        case .couldNotStart: throw FocusIntentError.nothingToBlock
        }
    }
}

struct GetFocusStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Focus Status"
    static let description = IntentDescription(
        "Says whether a focus session is running, paused or on a break, how many minutes are left, and whether it's strict. It changes nothing.",
        categoryName: "Focus")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<FocusStatusEntity> & ProvidesDialog {
        let model = try await NidusModel.forIntent()
        let status = model.commandStatus
        return .result(value: FocusStatusEntity(status), dialog: "\(status.sentence)")
    }
}

struct AddFocusTimeIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Focus Time"
    static let description = IntentDescription(
        "Adds minutes to the focus session that's on. A session can't run more than 24 hours, and an open-ended one has no end to move.",
        categoryName: "Focus")

    @Parameter(title: "Minutes", description: "How many to add, from 1 to 1440.", default: 5, inclusiveRange: (1, 1440))
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$minutes) minutes of focus")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<FocusStatusEntity> & ProvidesDialog {
        let model = try await NidusModel.forIntent()
        switch model.addTimeFromOutside(minutes: minutes) {
        case .added(let added):
            let status = model.commandStatus
            let left = status.sessionMinutesLeft.map { " You have \(FocusFormat.minutes($0)) left." } ?? ""
            return .result(value: FocusStatusEntity(status), dialog: "Added \(FocusFormat.minutes(added)).\(left)")
        case .atMaximum: throw FocusIntentError.atMaximum
        case .openEnded: throw FocusIntentError.openEnded
        case .onBreak: throw FocusIntentError.onBreak
        case .nothingRunning: throw FocusIntentError.nothingRunning
        case .invalidMinutes: throw FocusIntentError.addMinutesOutOfRange
        }
    }
}

/// For scripts and assistants: one JSON request in, one JSON answer out,
/// with the same rules as the other actions. A one-step shortcut around it
/// is what `shortcuts run` calls; docs/automation.md has the contract.
struct RunNidusCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Nidus Command"
    static let description = IntentDescription(
        "For scripts and assistants: takes a request in JSON (status, setups, start, addTime or end) and returns the result in JSON.",
        categoryName: "Automation")

    @Parameter(title: "Request", description: "A Nidus request in JSON, version 1.",
               inputOptions: String.IntentInputOptions(multiline: true))
    var request: String

    static var parameterSummary: some ParameterSummary {
        Summary("Run Nidus command \(\.$request)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // Not up within the wait: still an answer in JSON, so a script can
        // tell "not running" from a broken wrapper.
        let model = try? await NidusModel.forIntent()
        let ledger = model?.commandLedger ?? FocusCommandLedger()
        return .result(value: FocusCommands.respond(to: request, target: model, ledger: ledger))
    }
}

// MARK: - Phrases

/// Phrases for App Shortcuts, which Apple offers on iPhone and iPad but not
/// on macOS; kept so the metadata stays complete. Every phrase says the app's
/// name, as the system requires.
struct NidusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartFocusIntent(),
            phrases: ["Start focus in \(.applicationName)",
                      "Start a focus session in \(.applicationName)",
                      "Focus with \(.applicationName)"],
            shortTitle: "Start Focus", systemImageName: "scope")
        AppShortcut(
            intent: EndFocusIntent(),
            phrases: ["End focus in \(.applicationName)",
                      "Stop focus in \(.applicationName)"],
            shortTitle: "End Focus", systemImageName: "stop.circle")
        AppShortcut(
            intent: ToggleFocusIntent(),
            phrases: ["Toggle focus in \(.applicationName)"],
            shortTitle: "Toggle Focus", systemImageName: "playpause")
        AppShortcut(
            intent: AddFocusTimeIntent(),
            phrases: ["Add focus time in \(.applicationName)"],
            shortTitle: "Add Focus Time", systemImageName: "plus.circle")
        AppShortcut(
            intent: GetFocusStatusIntent(),
            phrases: ["Is focus on in \(.applicationName)",
                      "How much focus time is left in \(.applicationName)"],
            shortTitle: "Focus Status", systemImageName: "timer")
    }
}
