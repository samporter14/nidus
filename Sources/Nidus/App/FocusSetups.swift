//
//  FocusSetups.swift
//  Nidus
//
//  Saved setups: a session you run often, kept so it starts in one click
//  from the popover or the right-click menu. "Deep work" is 90 minutes, only
//  Xcode, strict; "Writing" is 45 minutes of Social, Video and Messaging.
//
//  The conversions are pure functions of the setup and the live categories,
//  so they are tested without a model; the model's side is a thin wrapper
//  that stores the list and starts one.
//

import AppKit
import SwiftUI

extension NidusModel.Key {
    static let setups = "setups"
}

struct FocusSetup: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// An SF Symbol.
    var symbol: String
    /// 0 means open-ended.
    var minutes: Int
    /// FocusCategory ids. A category deleted since is dropped when the setup
    /// starts, not here, so the list is never edited behind the user's back.
    var categoryIDs: [String]
    var mode: SessionPlan.Mode
    var strict: Bool
    /// Used when no goal is typed in the popover.
    var goal: String?

    static let defaultName = "New setup"
    static let defaultSymbol = "bolt"

    init(id: UUID = UUID(), name: String = FocusSetup.defaultName, symbol: String = FocusSetup.defaultSymbol,
         minutes: Int = 25, categoryIDs: [String] = [], mode: SessionPlan.Mode = .block,
         strict: Bool = false, goal: String? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.minutes = minutes
        self.categoryIDs = categoryIDs
        self.mode = mode
        self.strict = strict
        self.goal = goal
    }

    /// Only the id and name must be there. A field a later version adds, or
    /// one that does not decode, falls back to a default: settings that fail
    /// to decode are read as empty, which would wipe every setup at once.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        symbol = (try? container.decodeIfPresent(String.self, forKey: .symbol)) ?? Self.defaultSymbol
        minutes = (try? container.decodeIfPresent(Int.self, forKey: .minutes)) ?? 25
        categoryIDs = (try? container.decodeIfPresent([String].self, forKey: .categoryIDs)) ?? []
        mode = (try? container.decodeIfPresent(SessionPlan.Mode.self, forKey: .mode)) ?? .block
        strict = (try? container.decodeIfPresent(Bool.self, forKey: .strict)) ?? false
        goal = (try? container.decodeIfPresent(String.self, forKey: .goal)) ?? nil
    }

    /// The name as shown: a cleared name is never an empty button or menu item.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    // MARK: Starting

    /// The ids that still name a category, in the setup's order.
    func liveCategoryIDs(in categories: [FocusCategory]) -> [String] {
        categoryIDs.filter { id in categories.contains { $0.id == id } }
    }

    /// The goal a start uses: what is typed in the popover, else the setup's
    /// own, else none. A goal typed for one session never becomes the setup's.
    static func resolvedGoal(typed: String, saved: String?) -> String? {
        for candidate in [typed, saved ?? ""] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// The session to start. Length, categories, mode and strict are always
    /// set, never nil: nil takes the popover's current choice, which would
    /// run a different session from the one on the button. A setup left with
    /// no categories sends `[]`, not nil, for the same reason.
    func request(categories: [FocusCategory], goalDraft: String = "") -> SessionRequest {
        SessionRequest(goal: Self.resolvedGoal(typed: goalDraft, saved: goal),
                       minutes: minutes,
                       categoryIDs: liveCategoryIDs(in: categories),
                       mode: mode,
                       strict: strict)
    }

    /// A setup from what the popover has chosen now: its length, categories,
    /// mode and strictness. A goal typed there is not kept: a goal belongs
    /// to one session. Selected categories that no longer exist are left out.
    static func saving(minutes: Int, selectedIDs: [String], mode: SessionPlan.Mode, strict: Bool,
                       categories: [FocusCategory]) -> FocusSetup {
        FocusSetup(minutes: minutes,
                   categoryIDs: selectedIDs.filter { id in categories.contains { $0.id == id } },
                   mode: mode, strict: strict)
    }

    // MARK: Whether it can start

    enum Problem: Equatable, Sendable {
        /// It names categories and every one has been deleted.
        case categoriesGone
        /// A block list session with nothing in it to block.
        case nothingToBlock

        var reason: String {
            switch self {
            case .categoriesGone: return "Its categories are gone"
            case .nothingToBlock: return "Nothing to block"
            }
        }
    }

    /// Why this can't start now, or nil. It mirrors `NidusModel.startSession`,
    /// which refuses a block list session whose categories are all empty, and
    /// goes one step further. An allow list session with every category gone
    /// would hide every app, so it doesn't start either: the setup was saved
    /// to keep something open, and that something no longer exists.
    func problem(in categories: [FocusCategory]) -> Problem? {
        let live = liveCategoryIDs(in: categories)
        if !categoryIDs.isEmpty, live.isEmpty { return .categoriesGone }
        if mode == .block, !categories.contains(where: { live.contains($0.id) && !$0.isEmpty }) { return .nothingToBlock }
        return nil
    }

    // MARK: Saying what it is

    /// "45 min · Social, Video", "1 hr 30 min · Only Xcode · strict": for a
    /// subtitle. The length reads as it does in the popover's menu and in
    /// Settings, so 90 minutes is "1 hr 30 min" everywhere.
    func planSummary(categories: [FocusCategory]) -> String {
        let live = liveCategoryIDs(in: categories)
        // In the categories' own order, as the popover lists them.
        let names = categories.filter { live.contains($0.id) }.map(\.name)
        var parts = [FocusFormat.duration(minutes: minutes), Self.scope(names: names, mode: mode)]
        if strict { parts.append("strict") }
        return parts.joined(separator: " · ")
    }

    /// "Social, Video"; "Only Xcode" for an allow list; a count once the
    /// names stop fitting, as the popover's category menu does.
    static func scope(names: [String], mode: SessionPlan.Mode) -> String {
        let list: String
        switch names.count {
        case 0: return mode == .allow ? "Nothing allowed" : "Nothing to block"
        case 1, 2: list = names.joined(separator: ", ")
        default: list = "\(names.count) categories"
        }
        return mode == .allow ? "Only \(list)" : list
    }

    // MARK: Symbols

    /// What a setup's symbol is picked from: enough for the usual kinds of
    /// work, few enough to see at once.
    static let symbols: [(symbol: String, name: String)] = [
        ("brain.head.profile", "Brain"),
        ("pencil", "Pencil"),
        ("book", "Book"),
        ("graduationcap", "Graduation cap"),
        ("chevron.left.forwardslash.chevron.right", "Code"),
        ("flask", "Flask"),
        ("paintpalette", "Palette"),
        ("envelope", "Envelope"),
        ("bolt", "Bolt"),
        ("flame", "Flame"),
        ("leaf", "Leaf"),
        ("moon", "Moon"),
    ]

    // MARK: Order

    /// `list` with the setup `step` places later (earlier when negative),
    /// stopping at either end. Unchanged when the id isn't in it.
    static func moving(_ id: FocusSetup.ID, by step: Int, in list: [FocusSetup]) -> [FocusSetup] {
        guard let index = list.firstIndex(where: { $0.id == id }) else { return list }
        let target = min(max(index + step, 0), list.count - 1)
        guard target != index else { return list }
        var moved = list
        moved.insert(moved.remove(at: index), at: target)
        return moved
    }
}

// MARK: - The model's side

extension NidusModel {
    /// The saved setups, in the order they show. None to begin with.
    var setups: [FocusSetup] {
        get { preference(Key.setups, default: [FocusSetup]()) }
        set { setPreference(newValue, Key.setups) }
    }

    /// Starts a setup, with the goal typed in the popover if there is one.
    /// Returns false, starting nothing, when it can't: a session or break is
    /// on, or nothing is left to block. Callers show that beforehand
    /// (`FocusSetup.problem`), so the buttons that start one are dimmed.
    @discardableResult
    func start(_ setup: FocusSetup) -> Bool {
        let current = categories
        guard setup.problem(in: current) == nil else { return false }
        return startSession(setup.request(categories: current, goalDraft: goalDraft))
    }

    func updateSetup(_ id: FocusSetup.ID, _ change: (inout FocusSetup) -> Void) {
        var all = setups
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[index])
        setups = all
    }

    func deleteSetup(_ id: FocusSetup.ID) {
        setups.removeAll { $0.id == id }
        host?.workspace.goBackInSettings()
    }

    func moveSetup(_ id: FocusSetup.ID, by step: Int) {
        setups = FocusSetup.moving(id, by: step, in: setups)
    }

    /// Saves the popover's current length, categories, mode and strictness
    /// as a new setup, last in the list. Its name and symbol are left for
    /// the user to set, on the page this opens.
    @discardableResult
    func addSetupFromCurrentChoices() -> FocusSetup {
        let setup = FocusSetup.saving(minutes: durationMinutes, selectedIDs: selectedCategoryIDs,
                                      mode: mode, strict: strictMode, categories: categories)
        setups.append(setup)
        openSetupPage(setup)
        return setup
    }

    // MARK: Pages

    nonisolated static let setupsPageID = "setups"
    nonisolated static let setupPagePrefix = "setup:"

    /// These open from the popover as well as from Settings; the popover
    /// closes so it isn't left open over the window.
    func openSetupsPage() {
        menuBarItem?.closePopover()
        host?.workspace.openSettingsPage(Self.setupsPageID, title: "Setups")
    }

    func openSetupPage(_ setup: FocusSetup) {
        menuBarItem?.closePopover()
        host?.workspace.openSettingsPage(Self.setupPagePrefix + setup.id.uuidString, title: setup.displayName)
    }

    /// The list at `setups` and each setup's page at `setup:<id>`; nil for a
    /// setup that has been deleted.
    func makeSetupsPage(id: String) -> AnyView? {
        if id == Self.setupsPageID { return AnyView(FocusSetupsPage(model: self)) }
        guard id.hasPrefix(Self.setupPagePrefix),
              let setupID = UUID(uuidString: String(id.dropFirst(Self.setupPagePrefix.count))),
              setups.contains(where: { $0.id == setupID }) else { return nil }
        return AnyView(FocusSetupPage(model: self, setupID: setupID))
    }

    // MARK: The menu bar's menu

    /// The setups' items for the right-click menu, to follow "Start focus":
    /// none without setups.
    func setupMenuItems() -> [NSMenuItem] {
        FocusSetupsMenu.items(for: setups, categories: categories,
                              target: self, action: #selector(startSetupFromMenu(_:)))
    }

    @objc func startSetupFromMenu(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let id = UUID(uuidString: text),
              let setup = setups.first(where: { $0.id == id }) else { return }
        start(setup)
    }
}

/// The right-click menu's setup items, built apart from the model so they can
/// be tested.
enum FocusSetupsMenu {
    /// Up to this many go straight in the menu; more go under "Start a setup".
    static let inlineLimit = 4
    static let submenuTitle = "Start a setup"

    @MainActor
    static func items(for setups: [FocusSetup], categories: [FocusCategory],
                      target: AnyObject?, action: Selector) -> [NSMenuItem] {
        guard !setups.isEmpty else { return [] }
        let items = setups.map { item(for: $0, categories: categories, target: target, action: action) }
        guard setups.count > inlineLimit else { return items }
        let submenu = NSMenu(title: submenuTitle)
        items.forEach(submenu.addItem)
        let parent = NSMenuItem(title: submenuTitle, action: nil, keyEquivalent: "")
        parent.image = symbolImage("bolt")
        parent.submenu = submenu
        return [parent]
    }

    /// A setup that can't start has no action, so the menu leaves it dimmed:
    /// setting `isEnabled` alone is undone by the menu's auto-enabling.
    @MainActor
    private static func item(for setup: FocusSetup, categories: [FocusCategory],
                             target: AnyObject?, action: Selector) -> NSMenuItem {
        let problem = setup.problem(in: categories)
        let item = NSMenuItem(title: setup.displayName, action: problem == nil ? action : nil, keyEquivalent: "")
        item.target = target
        item.representedObject = setup.id.uuidString
        item.subtitle = problem?.reason ?? setup.planSummary(categories: categories)
        item.image = symbolImage(setup.symbol)
        return item
    }

    @MainActor
    static func symbolImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}
