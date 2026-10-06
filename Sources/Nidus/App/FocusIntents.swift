//
//  FocusIntents.swift
//  Nidus
//
//  Shortcuts actions: Start Focus, End Focus, Toggle Focus and Get Focus
//  Status, and the phrases Siri and Spotlight know them by. They run in the
//  menu bar app's own process and reach the model through NidusModel.running
//  (FocusOutside.swift), so they answer to the same rules as a nidus:// link,
//  strict mode first.
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

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Nidus is still starting. Try again in a moment."
        case .strict: "This is a strict session. End it from the menu bar."
        case .busy: "A focus session or a break is already on."
        case .nothingToBlock: "There is nothing to block. Add apps or websites to a category in Nidus."
        case .minutesOutOfRange: "Minutes must be from 0 to 1440."
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

// MARK: - Status

/// What Get Focus Status hands back: Shortcuts reads its fields.
struct FocusStatusEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Focus status")

    @Property(title: "Session on")
    var isOn: Bool

    @Property(title: "Minutes left")
    var minutesLeft: Int?

    init() {}

    init(_ status: FocusStatus) {
        isOn = status.isOn
        minutesLeft = status.minutesLeft
    }

    var displayRepresentation: DisplayRepresentation {
        let status = FocusStatus(isActive: isOn, isOpenEnded: minutesLeft == nil,
                                 remaining: TimeInterval((minutesLeft ?? 0) * 60))
        return DisplayRepresentation(title: "\(status.sentence)")
    }
}

// MARK: - Actions

struct StartFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Focus"
    static let description = IntentDescription(
        "Starts a focus session that blocks distracting apps and websites.",
        categoryName: "Focus")

    @Parameter(title: "Goal", description: "What you're working on.")
    var goal: String?

    @Parameter(title: "Minutes", description: "How long. 0 is open-ended. Your usual length if you leave it out.",
               inclusiveRange: (0, 1440))
    var minutes: Int?

    @Parameter(title: "Categories", description: "What to block. Your picks in Nidus if you leave it out.")
    var categories: [FocusCategoryEntity]?

    static var parameterSummary: some ParameterSummary {
        Summary("Start focus") {
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
        let request = SessionRequest(goal: NidusLink.cleanedGoal(goal ?? ""), minutes: minutes, categoryIDs: ids)
        switch model.startFromOutside(request) {
        case .started: return .result(dialog: "Focus started.")
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
        "Says whether a focus session is on, and how many minutes are left.",
        categoryName: "Focus")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<FocusStatusEntity> & ProvidesDialog {
        let model = try await NidusModel.forIntent()
        let status = model.focusStatus
        return .result(value: FocusStatusEntity(status), dialog: "\(status.sentence)")
    }
}

// MARK: - Phrases

/// What Siri and Spotlight answer to. Every phrase says the app's name, as the
/// system requires.
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
            intent: GetFocusStatusIntent(),
            phrases: ["Is focus on in \(.applicationName)",
                      "How much focus time is left in \(.applicationName)"],
            shortTitle: "Focus Status", systemImageName: "timer")
    }
}
