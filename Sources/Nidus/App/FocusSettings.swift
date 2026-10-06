//
//  FocusSettings.swift
//  Nidus
//
//  Settings: the main page, and a page per category, Stats and Apps to
//  open. Built from the rows in Kit.swift: a grouped form, as System Settings.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension NidusModel {
    func makeSettingsPage(id: String) -> AnyView? {
        switch id {
        case "stats": return AnyView(FocusStatsPage(model: self))
        case "launch-apps": return AnyView(FocusLaunchAppsPage(model: self))
        default: break
        }
        guard id.hasPrefix(Self.categoryPagePrefix) else { return nil }
        let categoryID = String(id.dropFirst(Self.categoryPagePrefix.count))
        guard categories.contains(where: { $0.id == categoryID }) else { return nil }
        return AnyView(FocusCategoryPage(model: self, categoryID: categoryID))
    }

    static let categoryPagePrefix = "category:"

    func openCategoryPage(_ category: FocusCategory) {
        host?.workspace.openSettingsPage(Self.categoryPagePrefix + category.id, title: category.name)
    }

    func addCategory() {
        let category = FocusCategory(id: UUID().uuidString, name: "New category", symbol: "square.grid.2x2",
                                     apps: [], websites: [])
        categories.append(category)
        openCategoryPage(category)
    }

    func updateCategory(_ id: String, _ change: (inout FocusCategory) -> Void) {
        var all = categories
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[index])
        categories = all
    }

    func deleteCategory(_ id: String) {
        categories.removeAll { $0.id == id }
        selectedCategoryIDs.removeAll { $0 == id }
        host?.workspace.goBackInSettings()
    }
}

// MARK: - The pane

struct FocusSettingsPane: View {
    @ObservedObject var model: NidusModel

    @State private var opensAtLogin = LoginItem.isOn

    var body: some View {
        DropletSettingsPane {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nidus")
                            .font(.title2.weight(.semibold))
                        Text("Blocks what pulls you away, for as long as you say. Nothing leaves this Mac.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .padding(.vertical, 4)
            }

            DropletSettingsCard {
                DropletSettingsPageLink("Stats", subtitle: statsSummary, page: "stats") {
                    CategoryTile(symbol: "chart.bar.xaxis")
                }
            }

            if model.showsGettingStarted {
                DropletSettingsSection {
                    VStack(alignment: .leading, spacing: 2) {
                        settingsSectionHeader("Get started")
                        Text("Where Nidus lives, and how to begin.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } content: {
                    DropletSettingsCard {
                        FocusStepRow(
                            title: "Start from the menu bar",
                            detail: Text("Click \(FocusWelcomeCard.inlineGlyph) in the menu bar, type what you're working on, then press Start. Right-click it for a quick menu. If you use a menu bar manager, check it isn't hiding the icon.")
                        ) {
                            CategoryTile(image: FocusWelcomeCard.glyph)
                        }
                        FocusStepRow(
                            title: "Choose what to block",
                            detail: Text("Pick categories below, or make your own. The first time Nidus reaches a browser, macOS asks whether Nidus may control it.")
                        ) {
                            CategoryTile(symbol: "nosign")
                        }
                        DropletControlRow(title: "This guide goes after your first session") {
                            Button("Hide now", action: model.hideGettingStarted)
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Sessions")
            } content: {
                DropletSettingsCard {
                    DropletGroupedPickerRow(title: "Session length",
                                            subtitle: "What a new session starts with. You can add time while it runs.") {
                        Picker("Session length", selection: model.binding(\.durationMinutes)) {
                            ForEach(NidusModel.durationChoices, id: \.self) { minutes in
                                Text(FocusFormat.duration(minutes: minutes)).tag(minutes)
                            }
                        }
                    }
                    DropletGroupedPickerRow(title: "Break after a session",
                                            subtitle: "When a session runs its full length, a break starts. When the break ends, the next session starts with the same goal.") {
                        Picker("Break after a session", selection: model.binding(\.breakMinutes)) {
                            ForEach(NidusModel.breakChoices, id: \.self) { minutes in
                                Text(minutes == 0 ? "No break" : FocusFormat.duration(minutes: minutes)).tag(minutes)
                            }
                        }
                    }
                    DropletToggleRow(title: "Strict mode",
                                     subtitle: "No snooze or pause during a session, and ending one early means typing \u{201C}stop early\u{201D} in the popover. Applies to sessions you start from now on.",
                                     isOn: model.binding(\.strictMode))
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Blocking")
            } content: {
                DropletSettingsCard {
                    DropletGroupedPickerRow(title: "What to block",
                                            subtitle: "Block the categories you pick, or block everything except them.") {
                        Picker("What to block", selection: model.binding(\.mode)) {
                            Text("Block list").tag(SessionPlan.Mode.block)
                            Text("Allow list").tag(SessionPlan.Mode.allow)
                        }
                        .pickerStyle(.segmented)
                    }
                    DropletGroupedPickerRow(title: "When a blocked app opens",
                                            subtitle: "Quitting asks the app to close normally, so it can save your work.") {
                        Picker("When a blocked app opens", selection: model.binding(\.hidesInsteadOfQuitting)) {
                            Text("Quit it").tag(false)
                            Text("Hide it").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    DropletGroupedPickerRow(title: "Snooze length",
                                            subtitle: "How long Snooze lets one app or website through.") {
                        Picker("Snooze length", selection: model.binding(\.snoozeMinutes)) {
                            ForEach(NidusModel.snoozeChoices, id: \.self) { minutes in
                                Text(FocusFormat.duration(minutes: minutes)).tag(minutes)
                            }
                        }
                    }
                    .disabled(model.strictMode)
                    DropletGroupedPickerRow(title: "Before a snooze",
                                            subtitle: "A short wait gets you past the impulse.") {
                        Picker("Before a snooze", selection: model.binding(\.snoozeWaitSeconds)) {
                            ForEach(SnoozeWait.choices, id: \.self) { seconds in
                                Text(SnoozeWait.choiceLabel(seconds)).tag(seconds)
                            }
                        }
                    }
                    .disabled(model.strictMode)
                    DropletToggleRow(title: "Reopen quit apps",
                                     subtitle: "When a session ends, opens the apps it quit, in the background.",
                                     isOn: model.binding(\.reopensQuitApps))
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Nidus")
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(title: "Time left in the menu bar",
                                     subtitle: "Shows the countdown beside the brain while a session runs.",
                                     isOn: model.binding(\.menuBarShowsTime))
                    DropletToggleRow(title: "Open at login",
                                     subtitle: "A session left running carries on after a restart.",
                                     isOn: Binding(get: { opensAtLogin },
                                                   set: { LoginItem.set($0); opensAtLogin = LoginItem.isOn }))
                }
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("When a session starts")
                    Text("Open what you work in, and quiet the rest of your Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } content: {
                DropletSettingsCard {
                    DropletSettingsPageLink("Apps to open", subtitle: launchSummary, page: "launch-apps") {
                        CategoryTile(symbol: "macwindow.on.rectangle")
                    }
                }
                if FocusShortcuts.isAvailable {
                    DropletSettingsCard {
                        FocusShortcutRows(model: model)
                    }
                }
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Categories")
                    Text("Pick one or more when you start a session.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } content: {
                DropletSettingsCard {
                    ForEach(model.categories) { category in
                        DropletSettingsPageLink(
                            category.name,
                            subtitle: category.summary,
                            page: NidusModel.categoryPagePrefix + category.id
                        ) {
                            CategoryTile(symbol: category.symbol)
                        }
                    }
                    DropletControlRow(title: "New category") {
                        Button("Add", action: model.addCategory)
                            .buttonStyle(.bordered)
                    }
                }
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Browsers")
                    Text("Blocked websites are redirected in these browsers. Nidus needs permission to control each one.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } content: {
                DropletSettingsCard {
                    ForEach(BrowserProfile.known.filter(\.isInstalled), id: \.bundleID) { browser in
                        BrowserAccessRow(model: model, browser: browser)
                    }
                }
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Privacy")
                    Text("Nidus collects nothing and never connects to the internet. What it keeps stays on this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(title: "Record session history",
                                     subtitle: "Used only for your stats and recent goals, and kept only on this Mac. When off, neither is kept.",
                                     isOn: model.binding(\.recordsHistory))
                }
            }
        }
    }
}

extension FocusSettingsPane {
    var statsSummary: String {
        let stats = model.stats
        guard !stats.isEmpty else { return "Your sessions will show up here." }
        let streak = stats.currentStreak > 0 ? " · \(stats.currentStreak)-day streak" : ""
        return "\(FocusFormat.long(stats.focusedThisWeek)) this week\(streak)"
    }

    var launchSummary: String {
        let names = model.launchApps.map(\.name)
        switch names.count {
        case 0: return "None"
        case 1, 2: return names.joined(separator: ", ")
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }
}

/// A category's tile: its symbol in ink on clay. One colour for every
/// category keeps the list calm.
struct CategoryTile: View {
    let image: Image

    init(symbol: String) { image = Image(systemName: symbol) }
    init(image: Image) { self.image = image }

    var body: some View {
        SettingsTile(image: image, size: DropletSettingsPageLink<EmptyView>.tileSize)
    }
}

/// One step of the Get started guide, laid out like a page link without the
/// chevron: a tile, a title, and a line under it.
struct FocusStepRow<Tile: View>: View {
    let title: String
    let detail: Text
    @ViewBuilder let tile: () -> Tile

    var body: some View {
        HStack(alignment: .center, spacing: DroppySpacing.md) {
            tile()
                .frame(width: DropletSettingsPageLink<EmptyView>.tileSize,
                       height: DropletSettingsPageLink<EmptyView>.tileSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                detail
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Browser access

extension BrowserProfile {
    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// "Chrome" rather than "Google Chrome", where space is short.
    var shortName: String { name.replacingOccurrences(of: "Google ", with: "") }
}

/// One browser's Automation permission, and the one action that fixes it.
struct BrowserAccessRow: View {
    @ObservedObject var model: NidusModel
    let browser: BrowserProfile
    @State private var status: Status = .unknown
    @State private var isAsking = false

    enum Status: Equatable {
        case unknown, notRunning, allowed, notAsked, denied
    }

    var body: some View {
        DropletControlRow(title: browser.name) {
            HStack(spacing: DroppySpacing.sm) {
                Text(label)
                    .foregroundStyle(.secondary)
                switch status {
                case .notAsked:
                    Button("Allow…", action: ask)
                        .buttonStyle(.bordered)
                        .disabled(isAsking)
                case .denied:
                    Button("Open System Settings…", action: openAutomationSettings)
                        .buttonStyle(.bordered)
                default:
                    EmptyView()
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(model.controller?.$browserAccess.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in
            refresh()
        }
    }

    private var label: String {
        switch status {
        case .unknown: return ""
        case .notRunning: return "Open it to check"
        case .allowed: return "Allowed"
        case .notAsked: return "Not allowed yet"
        case .denied: return "Not allowed"
        }
    }

    private func refresh() {
        guard let target = AppleEventTarget(runningBundleID: browser.bundleID) else {
            status = .notRunning
            return
        }
        switch target.automationPermission(ask: false) {
        case nil: status = .allowed
        case .needsConsent: status = .notAsked
        case .notPermitted: status = .denied
        case .notRunning: status = .notRunning
        default: status = .unknown
        }
    }

    private func ask() {
        isAsking = true
        model.askBrowserAccess(browser) {
            isAsking = false
            refresh()
        }
    }

    private func openAutomationSettings() { model.openAutomationSettings() }
}

// MARK: - A category's page

struct FocusCategoryPage: View {
    @ObservedObject var model: NidusModel
    let categoryID: String
    @State private var newWebsite = ""

    private var category: FocusCategory? {
        model.categories.first { $0.id == categoryID }
    }

    var body: some View {
        DropletSettingsPage {
            if let category {
                DropletSettingsCard {
                    DropletControlRow(title: "Name") {
                        TextField("Name", text: nameBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .labelsHidden()
                    }
                }

                DropletSettingsSection {
                    settingsSectionHeader("Apps")
                } content: {
                    DropletSettingsCard {
                        ForEach(category.apps) { app in
                            DropletControlRow(title: app.name) {
                                removeButton("Remove \(app.name)") {
                                    model.updateCategory(categoryID) { $0.apps.removeAll { $0.bundleID == app.bundleID } }
                                }
                            }
                        }
                        DropletControlRow(title: category.apps.isEmpty ? "No apps yet" : "Add more") {
                            Button("Choose apps…", action: chooseApps)
                                .buttonStyle(.bordered)
                        }
                    }
                }

                DropletSettingsSection {
                    VStack(alignment: .leading, spacing: 2) {
                        settingsSectionHeader("Websites")
                        Text("Each one also covers its subdomains, so youtube.com includes m.youtube.com.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } content: {
                    DropletSettingsCard {
                        ForEach(category.websites, id: \.self) { site in
                            DropletControlRow(title: site) {
                                removeButton("Remove \(site)") {
                                    model.updateCategory(categoryID) { $0.websites.removeAll { $0 == site } }
                                }
                            }
                        }
                        DropletControlRow(title: "Add a website") {
                            HStack(spacing: DroppySpacing.sm) {
                                TextField("example.com", text: $newWebsite)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 180)
                                    .labelsHidden()
                                    .onSubmit(addWebsite)
                                Button("Add", action: addWebsite)
                                    .buttonStyle(.bordered)
                                    .disabled(FocusCategory.domain(from: newWebsite) == nil)
                            }
                        }
                    }
                }

                DropletSettingsCard {
                    DropletControlRow(title: "Delete this category") {
                        Button("Delete", role: .destructive) { model.deleteCategory(categoryID) }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { category?.name ?? "" },
            set: { name in model.updateCategory(categoryID) { $0.name = name } }
        )
    }

    private func removeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private func addWebsite() {
        guard let domain = FocusCategory.domain(from: newWebsite) else { return }
        model.updateCategory(categoryID) { category in
            if !category.websites.contains(domain) { category.websites.append(domain) }
        }
        newWebsite = ""
    }

    private func chooseApps() {
        let apps = AppChooser.choose(title: "Choose apps to block")
        model.updateCategory(categoryID) { category in
            for app in apps where !category.apps.contains(where: { $0.bundleID == app.bundleID }) {
                category.apps.append(app)
            }
        }
    }
}

// MARK: - Apps to open

struct FocusLaunchAppsPage: View {
    @ObservedObject var model: NidusModel

    var body: some View {
        DropletSettingsPage {
            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Apps to open")
                    Text("Opened when a session starts, the first one in front. A session never blocks the apps it opened.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } content: {
                DropletSettingsCard {
                    ForEach(model.launchApps) { app in
                        DropletControlRow(title: app.name) {
                            Button {
                                model.launchApps.removeAll { $0.bundleID == app.bundleID }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove \(app.name)")
                            .accessibilityLabel("Remove \(app.name)")
                        }
                    }
                    DropletControlRow(title: model.launchApps.isEmpty ? "No apps yet" : "Add more") {
                        Button("Choose apps…") {
                            let chosen = AppChooser.choose(title: "Choose apps to open when a session starts")
                            var apps = model.launchApps
                            for app in chosen where !apps.contains(where: { $0.bundleID == app.bundleID }) { apps.append(app) }
                            model.launchApps = apps
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}

/// The system Open panel, pointed at /Applications, returning apps.
enum AppChooser {
    @MainActor
    static func choose(title: String) -> [BlockedApp] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { url in
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
            let name = FileManager.default.displayName(atPath: url.path)
            return BlockedApp(bundleID: bundleID, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
        }
    }
}

// MARK: - Apple Focus

/// Two shortcuts, run when a session starts and ends. macOS lets only
/// Shortcuts change a Focus mode, so this is the way to Do Not Disturb.
struct FocusShortcutRows: View {
    @ObservedObject var model: NidusModel
    @State private var names: [String] = []
    @State private var isAdding = false
    @State private var note: String?
    /// Opening the shortcuts and waiting for the user to add them; it stops
    /// with the page, so nothing polls Shortcuts after Settings is closed.
    @State private var addTask: Task<Void, Never>?

    var body: some View {
        Group { rows }
            .task { names = await FocusShortcuts.list() }
            .onDisappear {
                addTask?.cancel()
                addTask = nil
                isAdding = false
            }
    }

    @ViewBuilder private var rows: some View {
        DropletGroupedPickerRow(title: "Turn on a Focus",
                                subtitle: "A shortcut run when a session starts, with the Set Focus action. Add… below makes them for Apple's Focus modes.") {
            Picker("Turn on a Focus", selection: binding(\.startShortcut)) {
                Text("None").tag("")
                ForEach(options(including: model.startShortcut), id: \.self) { Text($0).tag($0) }
            }
        }
        DropletGroupedPickerRow(title: "Turn it off", subtitle: "A shortcut run when the session ends.") {
            Picker("Turn it off", selection: binding(\.endShortcut)) {
                Text("None").tag("")
                ForEach(options(including: model.endShortcut), id: \.self) { Text($0).tag($0) }
            }
        }
        DropletControlRow(title: note ?? "Use an Apple Focus",
                          infoTip: "Pick a Focus you have set up in System Settings. Nidus makes two one-step shortcuts, one to turn it on and one to turn it off, and chooses them above; Shortcuts asks before adding each. For a Focus you made yourself, make the shortcut with Set Focus in Shortcuts and choose it above.") {
            Menu(isAdding ? "Adding…" : "Add…") {
                ForEach(FocusShortcuts.appleFocuses) { focus in
                    Button(hasShortcuts(for: focus) ? "\(focus.name) (added)" : focus.name) { add(focus) }
                }
            }
            // Drawn like the pickers above it; the bordered menu style reads
            // dark on dark inside the settings form.
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isAdding)
        }
    }

    private func hasShortcuts(for focus: FocusShortcuts.AppleFocus) -> Bool {
        names.contains(focus.onShortcut) && names.contains(focus.offShortcut)
    }

    /// The library's shortcuts, plus a chosen one that has since been renamed
    /// or deleted, so the picker never loses its selection silently.
    private func options(including chosen: String?) -> [String] {
        guard let chosen, !names.contains(chosen) else { return names }
        return [chosen] + names
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<NidusModel, String?>) -> Binding<String> {
        Binding(get: { model[keyPath: keyPath] ?? "" },
                set: { model[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    /// Chooses a Focus's pair, making it first when it is not in the library.
    private func add(_ focus: FocusShortcuts.AppleFocus) {
        if hasShortcuts(for: focus) { return choose(focus) }
        guard let directory = model.host?.environment.containerDirectory.appendingPathComponent("Shortcuts") else { return }
        isAdding = true
        note = nil
        addTask = Task {
            do {
                for url in try await FocusShortcuts.makeShortcuts(for: focus, in: directory) {
                    guard !Task.isCancelled else { return }
                    NSWorkspace.shared.open(url)
                    try? await Task.sleep(for: .seconds(1.5))
                }
                // Wait for the user to add both in Shortcuts, then choose them.
                for _ in 0..<60 {
                    guard !Task.isCancelled else { return }
                    names = await FocusShortcuts.list()
                    if hasShortcuts(for: focus) { break }
                    try? await Task.sleep(for: .seconds(2))
                }
                if !Task.isCancelled, hasShortcuts(for: focus) { choose(focus) }
            } catch {
                note = "Shortcuts couldn't make them"
            }
            isAdding = false
        }
    }

    private func choose(_ focus: FocusShortcuts.AppleFocus) {
        model.startShortcut = focus.onShortcut
        model.endShortcut = focus.offShortcut
    }
}
