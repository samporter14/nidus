//
//  SettingsJump.swift
//  Nidus
//
//  "Jump to" in the Settings window: a field over every tab that finds a
//  setting by what it is called or what you would call it ("break", "strict",
//  "calendar", "shortcut", "Plaque") and opens the tab or page it lives on.
//  The index below is a hand-kept list, not a crawl of the views: each entry
//  names the page it opens, and a test checks that every page is one Settings
//  can open and that the place it shows is the tab the page really belongs to.
//
//  Keyboard: ⌘F focuses the field, the arrow keys choose, Return opens, Esc
//  clears. Opening goes through the Settings window's own navigation
//  (workspace.openSettingsPage), so the tab, Back and the saved tab behave as
//  for any other link.
//

import AppKit
import SwiftUI

// MARK: - The index

/// One thing to jump to: what it is called, the page that has it, and the
/// other words people look for it by.
struct SettingsJumpEntry: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// A page id Settings opens (SettingsTabs.swift): a tab's own, or one
    /// pushed inside a tab.
    let page: String
    /// The part of the page it sits in, if worth saying: "Sessions".
    let section: String?
    /// The title Back shows over a pushed page; the entry's own by default.
    let pageTitle: String
    let keywords: [String]

    init(_ id: String, _ title: String, page: String, section: String? = nil,
         pageTitle: String? = nil, _ keywords: [String]) {
        self.id = id
        self.title = title
        self.page = page
        self.section = section
        self.pageTitle = pageTitle ?? title
        self.keywords = keywords
    }

    /// The tab the window opens it in.
    var tab: SettingsTab { SettingsRoute.resolve(page).tab }

    /// "General › Sessions": where it is.
    var place: String { ([tab.title] + [section].compactMap { $0 }).joined(separator: " \u{203A} ") }

    /// A stable row/section id, independent of its visible wording. Settings
    /// that belong to an individual item lead to its chooser, never an
    /// arbitrary first category or schedule.
    var anchorID: String? {
        switch id {
        case "general", "blocking", "setups", "schedules", "activity", "stats", "about",
             "apps-to-open", "inbox": nil
        case "exceptions": "categories"
        default: id
        }
    }
}

enum SettingsJumpIndex {
    static let maxResults = 8

    static let entries: [SettingsJumpEntry] = {
        let general = SettingsTab.general.pageID
        let blocking = SettingsTab.blocking.pageID
        return [
            // General
            .init("general", "General", page: general, ["settings", "preferences", "options", "main"]),
            .init("session-length", "Session length", page: general, section: "Sessions",
                  ["duration", "minutes", "hours", "how long", "default", "custom", "timer"]),
            .init("break", "Break after a session", page: general, section: "Sessions",
                  ["breaks", "rest", "pomodoro", "pause between", "next session", "no break"]),
            .init("strict", "Strict mode", page: general, section: "Sessions",
                  ["lock", "locked", "snooze", "pause", "stop early", "no escape", "commitment", "hard mode"]),
            .init("break-rules", "During a break", page: general, section: "During a break",
                  ["break rules", "blocked during break", "block on break", "reminder", "note to self", "break apps"]),
            .init("menu-bar-time", "Time left in the menu bar", page: general, section: "Menu bar and login",
                  ["countdown", "clock", "timer", "brain", "status item", "icon"]),
            .init("login", "Open at login", page: general, section: "Menu bar and login",
                  ["startup", "launch at login", "login item", "boot", "restart"]),
            .init("open-shortcut", "Open Nidus shortcut", page: general, section: "Menu bar and login",
                  ["shortcut", "keyboard", "hotkey", "hot key", "global", "key", "popover", "open", "toggle"]),
            .init("apps-to-open", "Apps to open", page: NidusModel.launchAppsPageID, section: "When a session starts",
                  pageTitle: "Apps to open", ["launch", "start apps", "open apps", "workspace", "when a session starts"]),
            .init("plaque", "Plaque", page: general, section: "Plaque",
                  ["e-paper", "epaper", "e-ink", "eink", "reader", "display", "status file", "show focus"]),
            .init("brick", "Phone focus requests", page: general, section: "Brick companion",
                  ["brick", "phone", "companion", "request", "session chooser"]),
            .init("get-started", "Get started guide", page: general, section: "Get started",
                  ["welcome", "guide", "first run", "help", "getting started", "hide"]),
            .init("inbox", "Inbox", page: NidusModel.inboxPageID, section: "Distraction inbox",
                  pageTitle: "Inbox", ["saved for later", "thoughts", "links", "distraction", "notes", "clear inbox", "save a thought"]),
            .init("capture-shortcut", "Capture shortcut", page: NidusModel.inboxPageID, section: "Distraction inbox",
                  pageTitle: "Inbox", ["shortcut", "keyboard", "hotkey", "hot key", "quick capture", "save a thought", "global", "key"]),
            .init("focus-shortcuts", "Do Not Disturb and Shortcuts", page: general, section: "When a session starts",
                  ["apple focus", "focus mode", "do not disturb", "shortcuts", "automation", "turn on a focus", "turn it off"]),

            // Blocking
            .init("blocking", "Blocking", page: blocking, ["block", "blocked", "distractions"]),
            .init("block-mode", "Block list or allow list", page: blocking, section: "What to block",
                  ["mode", "allow", "only allow", "whitelist", "blacklist", "everything except"]),
            .init("blocked-app", "When a blocked app opens", page: blocking,
                  ["quit", "hide", "close", "terminate", "save your work"]),
            .init("snooze", "Snooze", page: blocking, ["snooze length", "wait", "delay", "let through", "before a snooze"]),
            .init("reopen", "Reopen quit apps", page: blocking, ["restore", "relaunch", "reopen", "after a session"]),
            .init("categories", "Categories", page: blocking,
                  ["category", "apps", "websites", "social", "new category", "add category", "block list"]),
            .init("exceptions", "Website exceptions", page: blocking, section: "In a category",
                  ["exception", "let through", "allow a page", "address", "url", "path", "subpage", "website"]),
            .init("browsers", "Browsers", page: blocking,
                  ["browser", "safari", "chrome", "arc", "firefox", "brave", "automation", "permission", "access"]),

            // Setups
            .init("setups", "Setups", page: SettingsTab.setups.pageID,
                  ["setup", "preset", "one tap", "quick start", "launch link", "order", "documents", "web pages"]),
            .init("sequences", "Sequences", page: SettingsTab.setups.pageID, section: "Sequences",
                  ["sequence", "steps", "plan", "routine", "chain", "workday", "add a step"]),

            // Schedules
            .init("schedules", "Schedules", page: SettingsTab.schedules.pageID,
                  ["schedule", "weekly", "recurring", "days", "times", "automatic", "start by itself", "repeat"]),
            .init("calendar", "Check my calendar first", page: SettingsTab.schedules.pageID, section: "Calendar",
                  ["calendar", "meetings", "busy", "gap", "events", "gap around meetings", "calendar access"]),

            // Activity
            .init("activity", "Activity", page: SettingsTab.activity.pageID,
                  ["tracking", "record activity", "apps used", "time per app", "timeline", "websites",
                   "document names", "titles", "excluded apps", "recaps", "daily pattern"]),

            // Stats
            .init("stats", "Stats", page: SettingsTab.stats.pageID,
                  ["statistics", "streak", "time focused", "totals", "longest", "distractions", "most blocked"]),
            .init("projects", "Projects", page: SettingsTab.stats.pageID, section: "Projects",
                  ["project", "notes", "next steps", "goals", "unfinished", "resume", "archive"]),
            .init("history", "History", page: SettingsTab.stats.pageID, section: "History",
                  ["export", "clear history", "record sessions", "delete", "csv", "past sessions"]),

            // About
            .init("about", "About", page: SettingsTab.about.pageID,
                  ["version", "license", "mit", "credits", "nidus", "made by"]),
            .init("privacy", "Privacy and session history", page: SettingsTab.about.pageID, section: "Privacy",
                  ["privacy", "record session history", "data", "local", "this mac", "internet"]),
        ]
    }()

    /// The entries a query finds, best first. Every word of the query must
    /// start a word of the entry's name or keywords (plurals alike); words in
    /// the name count most. Nothing for an empty query.
    static func results(for query: String, limit: Int = maxResults) -> [SettingsJumpEntry] {
        let tokens = words(query)
        guard !tokens.isEmpty, limit > 0 else { return [] }
        let scored: [(entry: SettingsJumpEntry, score: Int, order: Int)] = entries.enumerated().compactMap { order, entry in
            let name = words(entry.title)
            let keywords = words(entry.keywords.joined(separator: " ") + " " + (entry.section ?? ""))
            let place = words(entry.tab.title)
            var total = 0
            for token in tokens {
                let score: Int
                if name.contains(where: { $0.hasPrefix(token) }) { score = 4 }
                else if keywords.contains(token) { score = 3 }
                else if keywords.contains(where: { $0.hasPrefix(token) }) { score = 2 }
                else if place.contains(where: { $0.hasPrefix(token) }) { score = 1 }
                else if token.count >= 3, (name + keywords).contains(where: { $0.contains(token) }) { score = 1 }
                else { return nil }
                total += score
            }
            // The whole query leading the name: "break" over "During a break".
            if let first = name.first, let lead = tokens.first, first.hasPrefix(lead) { total += 2 }
            return (entry, total, order)
        }
        return scored
            .sorted { ($0.score, -$0.order) > ($1.score, -$1.order) }
            .prefix(limit)
            .map(\.entry)
    }

    /// Lower case, accents folded, split at anything that isn't a letter or
    /// digit, a trailing "s" dropped from longer words so "exceptions" finds
    /// "exception" and "shortcut" finds "shortcuts".
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { word in
                let word = String(word)
                return word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
            }
    }
}

// MARK: - The state

/// What the field and the results share, across the tabs: one query, one
/// chosen row. `open` takes the page id and the title Back shows.
@MainActor @Observable
final class SettingsJump {
    var query = "" {
        didSet { if query != oldValue { selection = 0 } }
    }
    /// The row Return opens.
    var selection = 0
    /// Counts ⌘F presses; the field focuses itself when it changes.
    private(set) var focusRequest = 0
    /// A new identity lets selecting the same result scroll and emphasize it
    /// again. A newly-created tab can consume it on its first appearance.
    private(set) var destination: SettingsJumpDestination?
    private var destinationRevision = 0
    @ObservationIgnored private let opener: (String, String) -> Void

    init(open: @escaping (String, String) -> Void) { opener = open }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var results: [SettingsJumpEntry] { SettingsJumpIndex.results(for: query) }

    func requestFocus() { focusRequest += 1 }

    /// Down is +1, up is -1; stops at either end.
    func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    func openSelected() {
        let found = results
        guard found.indices.contains(selection) else { return }
        open(found[selection])
    }

    /// Clears the field and goes to the entry's page.
    func open(_ entry: SettingsJumpEntry) {
        query = ""
        destinationRevision += 1
        destination = entry.anchorID.map {
            SettingsJumpDestination(page: entry.page, anchor: $0, revision: destinationRevision)
        }
        opener(entry.page, entry.pageTitle)
    }

    func clear() { query = "" }

    func clearDestination() { destination = nil }
}

struct SettingsJumpDestination: Equatable, Sendable {
    let page: String
    let anchor: String
    let revision: Int

    func matches(page: String, anchor: String) -> Bool {
        self.page == page && self.anchor == anchor
    }
}

/// Optional environment values keep standalone previews/render fixtures
/// usable without a Settings window.
private struct SettingsJumpEnvironmentKey: EnvironmentKey {
    static let defaultValue: SettingsJump? = nil
}

private struct SettingsPageEnvironmentKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var settingsJump: SettingsJump? {
        get { self[SettingsJumpEnvironmentKey.self] }
        set { self[SettingsJumpEnvironmentKey.self] = newValue }
    }

    var settingsPageID: String {
        get { self[SettingsPageEnvironmentKey.self] }
        set { self[SettingsPageEnvironmentKey.self] = newValue }
    }
}

private struct SettingsJumpAnchor: ViewModifier {
    let anchor: String
    let aliases: [String]
    @Environment(\.settingsJump) private var jump
    @Environment(\.settingsPageID) private var page
    @State private var isHighlighted = false

    private var effectiveAnchor: String {
        guard let destination = jump?.destination, destination.page == page,
              aliases.contains(destination.anchor) else { return anchor }
        return destination.anchor
    }

    func body(content: Content) -> some View {
        content
            .id(effectiveAnchor)
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Solanum.clayText.opacity(isHighlighted ? 0.6 : 0), lineWidth: 1.5)
                    .padding(-3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .task(id: jump?.destination) {
                guard jump?.destination?.matches(page: page, anchor: effectiveAnchor) == true else {
                    isHighlighted = false
                    return
                }
                isHighlighted = true
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                isHighlighted = false
            }
    }
}

extension View {
    /// Marks a setting that Jump to can reveal and briefly emphasize.
    func settingsJumpAnchor(_ id: String, aliases: [String] = []) -> some View {
        modifier(SettingsJumpAnchor(anchor: id, aliases: aliases))
    }
}

// MARK: - The views

/// The field, over every tab.
struct SettingsJumpBar: View {
    let jump: SettingsJump

    var body: some View {
        JumpSearchField(jump: jump)
            .frame(height: 24)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }
}

/// What the query found, drawn over the tab's page while there is a query.
struct SettingsJumpResults: View {
    let jump: SettingsJump

    var body: some View {
        let found = jump.results
        VStack(alignment: .leading, spacing: 0) {
            if found.isEmpty {
                Text("No setting matches \u{201C}\(jump.query.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(found.enumerated()), id: \.element.id) { index, entry in
                        row(entry, isChosen: index == jump.selection)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                Text("\u{2191}\u{2193} choose \u{00B7} Return opens \u{00B7} Esc clears")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ entry: SettingsJumpEntry, isChosen: Bool) -> some View {
        Button {
            jump.open(entry)
        } label: {
            HStack(spacing: NidusSpacing.md) {
                Text(verbatim: entry.title)
                    .foregroundStyle(.primary)
                Spacer(minLength: NidusSpacing.md)
                Text(verbatim: entry.place)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isChosen ? FocusPalette.clay.opacity(0.22) : .clear, in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.title), \(entry.place)")
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

/// A search field that hands the arrow keys, Return and Escape to `jump`.
/// An AppKit field because its delegate hears those as editing commands
/// whatever the text field is doing, which SwiftUI's key handlers don't
/// promise for a field in a window that isn't the app's main one.
private struct JumpSearchField: NSViewRepresentable {
    let jump: SettingsJump

    func makeCoordinator() -> Coordinator { Coordinator(jump: jump) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Jump to a setting"
        field.setAccessibilityLabel("Jump to a setting")
        field.setAccessibilityHelp("Type to find a setting. Down arrow chooses, Return opens, Escape clears.")
        field.delegate = context.coordinator
        field.stringValue = jump.query
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        let coordinator = context.coordinator
        if field.stringValue != jump.query { field.stringValue = jump.query }
        if coordinator.handledFocus != jump.focusRequest, let window = field.window {
            coordinator.handledFocus = jump.focusRequest
            DispatchQueue.main.async { window.makeFirstResponder(field) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let jump: SettingsJump
        var handledFocus: Int

        init(jump: SettingsJump) {
            self.jump = jump
            handledFocus = jump.focusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            jump.query = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                jump.move(1)
            case #selector(NSResponder.moveUp(_:)):
                jump.move(-1)
            case #selector(NSResponder.insertNewline(_:)):
                jump.openSelected()
            case #selector(NSResponder.cancelOperation(_:)):
                // The first Escape clears; one more leaves the field.
                if jump.query.isEmpty { control.window?.makeFirstResponder(nil) } else { jump.clear() }
                control.stringValue = jump.query
            default:
                return false
            }
            return true
        }
    }
}
