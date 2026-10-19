//
//  FocusSetupWorkspaceViews.swift
//  Nidus
//
//  The part of a setup's page that says what it opens and runs: "When it
//  starts" (apps, documents and folders, web pages, Shortcuts) and
//  "Exceptions". Each is one line until opened. An override says "Uses
//  Settings" until it is changed, and can go back to that.
//
//  Anything that needs attention is a row of its own above the lines, so it
//  shows without opening them: a file that can't be found, and a page the
//  setup's own rules block, each with the one thing to do about it. A setup
//  with a blocked page still starts; the page opens and the block page
//  replaces it, as it would for any other.
//

import SwiftUI

/// A value with an id of its own, where the value's would repeat.
private struct Keyed<Value>: Identifiable {
    let id: String
    let value: Value
}

/// The lines of the page that open.
enum SetupPart: Hashable, Sendable {
    case apps, documents, pages, shortcuts, exceptions
    case project, breakLength, breakRules
}

/// Which app opens a document, as the page asks it. A render says its own.
private struct DefaultAppFinderKey: EnvironmentKey {
    static let defaultValue: any DefaultAppFinding = SystemAppFinder()
}

extension EnvironmentValues {
    var defaultAppFinder: any DefaultAppFinding {
        get { self[DefaultAppFinderKey.self] }
        set { self[DefaultAppFinderKey.self] = newValue }
    }
}

struct SetupWorkspaceSections: View {
    @ObservedObject var model: NidusModel
    let setupID: FocusSetup.ID
    @Environment(\.defaultAppFinder) private var appFinder

    @State private var opened: Set<SetupPart>
    @State private var locations: [WorkspaceResource.ID: WorkspaceLocation] = [:]
    /// The app that opens each document, read with `locations`.
    @State private var openers: [WorkspaceResource.ID: BlockedApp] = [:]
    @State private var shortcutNames: [String] = []
    @State private var pageDraft: String

    init(model: NidusModel, setupID: FocusSetup.ID, opened: Set<SetupPart> = [], pageDraft: String = "") {
        self.model = model
        self.setupID = setupID
        _opened = State(initialValue: opened)
        _pageDraft = State(initialValue: pageDraft)
    }

    private var setup: FocusSetup? { model.setups.first { $0.id == setupID } }

    var body: some View {
        if let setup {
            let conflicts = setup.conflicts(in: model.categories, openedBy: openers, settingsLaunchApps: model.launchApps)
            Group {
                startSection(setup, conflicts: conflicts)
                exceptionsSection(setup)
                projectAndBreakSection(setup)
            }
            .task(id: setup.resources) {
                locations = Self.locate(setup.resources)
                openers = WorkspaceConflicts.openers(for: setup.resources, launcher: WorkspaceLauncher(), finder: appFinder)
            }
            .task { await loadShortcuts() }
        }
    }

    // MARK: When it starts

    private func startSection(_ setup: FocusSetup, conflicts: [WorkspaceConflict]) -> some View {
        NidusSettingsSection {
            settingsSectionHeader("When it starts",
                                  detail: "Open what you work on and run your Shortcuts. Each line can use Settings\u{2019} choice instead.")
        } content: {
            NidusSettingsCard {
                attention(setup, conflicts: conflicts)
                line(.apps, "Apps", summary: setup.appsSummary) { appsRows(setup) }
                line(.documents, "Documents and folders", summary: documentsSummary(setup, conflicts: conflicts)) {
                    documentRows(setup, conflicts: conflicts)
                }
                line(.pages, "Web pages", summary: pagesSummary(setup, conflicts: conflicts)) { pageRows(setup, conflicts: conflicts) }
                if FocusShortcuts.isAvailable {
                    line(.shortcuts, "Shortcuts", summary: setup.shortcutsSummary) { shortcutRows(setup) }
                }
            }
        }
    }

    /// One line that opens: its title and a summary on the right, with its
    /// rows below once opened. Its own button rather than a DisclosureGroup,
    /// which clips the fields inside it.
    @ViewBuilder
    private func line<Content: View>(_ part: SetupPart, _ title: String, summary: String,
                                     @ViewBuilder rows: () -> Content) -> some View {
        let isOpen = opened.contains(part)
        Button {
            if isOpen { opened.remove(part) } else { opened.insert(part) }
        } label: {
            HStack(spacing: NidusSpacing.sm) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 12)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: NidusSpacing.md)
                Text(summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(summary)")
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .accessibilityHint(isOpen ? "Hides its settings" : "Shows its settings")
        if isOpen { rows() }
    }

    // MARK: Needs attention

    /// What can't work as saved, with the fix, whether or not its line is open.
    @ViewBuilder
    private func attention(_ setup: FocusSetup, conflicts: [WorkspaceConflict]) -> some View {
        // Their own ids: the lines below list the same resources, and two rows
        // in one form with the same id are drawn as one.
        ForEach(setup.resources.filter { locations[$0.id]?.problem != nil }.map { Keyed(id: "problem \($0.id)", value: $0) }) { item in
            let resource = item.value
            let reason = locations[resource.id]?.problem ?? .notFound
            LabeledContent {
                if resource.kind != .webPage {
                    Button("Choose again\u{2026}") { chooseAgain(resource) }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Choose \(resource.shownName) again")
                }
            } label: {
                Label(Self.problemTitle(for: resource, reason), systemImage: "exclamationmark.triangle")
                Text(Self.problemDetail(reason))
            }
        }
        ForEach(conflicts.map { Keyed(id: "conflict \($0.id)", value: $0) }) { item in
            let conflict = item.value
            LabeledContent {
                if conflict.hasFix {
                    Button(conflict.fixTitle) { allow(conflict) }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(conflict.app == nil ? "Allow only \(conflict.page)"
                                                                : "\(conflict.fixTitle) for \(conflict.page)")
                }
            } label: {
                Label(conflict.rowTitle, systemImage: "exclamationmark.triangle")
                Text(conflict.explanation)
            }
        }
    }

    static func problemTitle(for resource: WorkspaceResource, _ reason: WorkspaceProblemReason) -> String {
        switch reason {
        case .inTrash: return "\(resource.shownName) is in the Trash"
        case .notAWebAddress: return "\(resource.shownName) isn\u{2019}t a web address"
        case .couldNotOpen: return "\(resource.shownName) didn\u{2019}t open"
        case .notFound: return "\(resource.shownName) can\u{2019}t be found"
        }
    }

    static func problemDetail(_ reason: WorkspaceProblemReason) -> String {
        switch reason {
        case .notFound, .inTrash: return "It is skipped when the setup starts; the rest still opens. Choose it again to fix that."
        case .notAWebAddress: return "Remove it and add the page again."
        case .couldNotOpen: return "The Mac declined to open it."
        }
    }

    // MARK: Apps

    private func appsRows(_ setup: FocusSetup) -> some View {
        Group {
            NidusGroupedPickerRow(title: "Open", subtitle: setup.launchApps == nil ? settingsAppsLine
                                    : "These open instead of the apps in Settings, the first in front. A session never blocks the apps it opened.") {
                Picker("Apps to open", selection: ownApps) {
                    Text("Uses Settings").tag(false)
                    Text("Its own list").tag(true)
                }
            }
            if let apps = setup.launchApps {
                ForEach(apps) { app in
                    NidusControlRow(title: app.name) {
                        Button {
                            update { $0.launchApps?.removeAll { $0.bundleID == app.bundleID } }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(app.name)")
                        .accessibilityLabel("Remove \(app.name)")
                    }
                }
                NidusControlRow(title: apps.isEmpty ? "Opens no apps" : "Add more",
                                  infoTip: apps.isEmpty ? "Settings\u{2019} apps are not opened for this setup." : nil) {
                    Button("Choose apps\u{2026}", action: chooseApps)
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var settingsAppsLine: String {
        let names = model.launchApps.map(\.name)
        return names.isEmpty ? "Settings opens no apps." : "Settings opens \(FocusSetup.names(names))."
    }

    /// Settings\u{2019} list, or this setup\u{2019}s own (which may be empty: none).
    private var ownApps: Binding<Bool> {
        Binding(get: { setup?.launchApps != nil },
                set: { own in update { $0.launchApps = own ? [] : nil } })
    }

    private func chooseApps() {
        let chosen = AppChooser.choose(title: "Choose apps to open when this setup starts")
        update { setup in
            var apps = setup.launchApps ?? []
            for app in chosen where !apps.contains(where: { $0.bundleID == app.bundleID }) { apps.append(app) }
            setup.launchApps = apps
        }
    }

    // MARK: Documents and folders

    private func documentsSummary(_ setup: FocusSetup, conflicts: [WorkspaceConflict]) -> String {
        let missing = setup.documents.filter { locations[$0.id]?.problem != nil }.count
        let blocked = conflicts.filter { $0.app != nil }.count
        guard missing > 0 || blocked > 0 else { return setup.documentsSummary }
        let total = setup.documents.count
        var parts = ["\(total) \(total == 1 ? "item" : "items")"]
        if missing > 0 { parts.append("\(missing) missing") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func documentRows(_ setup: FocusSetup, conflicts: [WorkspaceConflict]) -> some View {
        Group {
            ForEach(setup.documents) { resource in
                let problem = locations[resource.id]?.problem
                let conflict = conflicts.first { $0.resourceID == resource.id }
                LabeledContent {
                    HStack(spacing: NidusSpacing.sm) {
                        if problem != nil {
                            Button("Choose again\u{2026}") { chooseAgain(resource) }
                                .buttonStyle(.bordered)
                        }
                        removeButton(resource)
                    }
                } label: {
                    Label(resource.shownName, systemImage: resource.kind == .folder ? "folder" : "doc")
                    Text(problem.map { Self.problemTitle(for: resource, $0) } ?? conflict?.reason
                         ?? Self.place(of: locations[resource.id]?.url ?? resource.path.map { URL(fileURLWithPath: $0) }))
                }
            }
            NidusControlRow(title: setup.documents.isEmpty ? "No documents or folders yet" : "Add more",
                              infoTip: setup.resources.count >= FocusSetup.resourceLimit
                                ? "A setup opens up to \(FocusSetup.resourceLimit) things." : "Opened with their usual app, or in Finder for a folder.") {
                Button("Choose\u{2026}", action: chooseDocuments)
                    .buttonStyle(.bordered)
                    .disabled(setup.resources.count >= FocusSetup.resourceLimit)
            }
        }
    }

    /// Where a file sits, as the Mac writes it: "~/Documents/Grants".
    static func place(of url: URL?) -> String {
        guard let url else { return "" }
        return (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseDocuments() {
        let urls = WorkspaceChooser.choose(title: "Choose documents and folders to open", prompt: "Add")
        let chosen = urls.map { WorkspaceResource.file(at: $0) }
        update { $0.add(chosen) }
    }

    private func chooseAgain(_ resource: WorkspaceResource) {
        let isFolder = resource.kind == .folder
        guard let url = WorkspaceChooser.choose(title: "Choose \(resource.shownName) again", prompt: "Choose",
                                                multiple: false, files: !isFolder, folders: isFolder).first else { return }
        let chosen = resource.choosing(url)
        update { $0.replace(resource.id, with: chosen) }
    }

    private func removeButton(_ resource: WorkspaceResource) -> some View {
        Button {
            update { $0.resources.removeAll { $0.id == resource.id } }
        } label: {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help("Remove \(resource.shownName)")
        .accessibilityLabel("Remove \(resource.shownName)")
    }

    // MARK: Web pages

    private func pagesSummary(_ setup: FocusSetup, conflicts: [WorkspaceConflict]) -> String {
        let blocked = conflicts.filter { $0.app == nil }.count
        guard blocked > 0 else { return setup.pagesSummary }
        let total = setup.pages.count
        return "\(total) \(total == 1 ? "page" : "pages") \u{00B7} \(blocked) blocked"
    }

    private func pageRows(_ setup: FocusSetup, conflicts: [WorkspaceConflict]) -> some View {
        Group {
            ForEach(setup.pages) { resource in
                let conflict = conflicts.first { $0.resourceID == resource.id }
                LabeledContent {
                    removeButton(resource)
                } label: {
                    Label(resource.shownName, systemImage: "globe")
                    Text(conflict?.reason ?? (resource.url ?? ""))
                }
            }
            NidusControlRow(title: setup.pages.isEmpty ? "No web pages yet" : "Add another",
                              infoTip: "http or https. Opens in your default browser.") {
                TextField("Paste a page address", text: $pageDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .labelsHidden()
                    .onSubmit(addPage)
                    .disabled(setup.resources.count >= FocusSetup.resourceLimit)
                    .accessibilityLabel("Address of a web page to open")
            }
            if let message = pageProblem {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            if !pageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, pageProblem == nil {
                HStack {
                    Spacer(minLength: 0)
                    Button("Add page", action: addPage)
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var pageProblem: String? {
        if case .failure(let problem) = WorkspaceResource.webPage(from: pageDraft) { return problem.message }
        return nil
    }

    private func addPage() {
        guard case .success(let page) = WorkspaceResource.webPage(from: pageDraft) else { return }
        update { $0.add([page]) }
        pageDraft = ""
    }

    // MARK: Shortcuts

    private func shortcutRows(_ setup: FocusSetup) -> some View {
        Group {
            NidusGroupedPickerRow(title: "Turn on a Focus",
                                    subtitle: setup.startShortcut == nil ? "Settings runs \(shortcutName(model.startShortcut))."
                                    : "Run when the session starts.") {
                Picker("Shortcut when it starts", selection: shortcut(\.startShortcut)) { shortcutChoices(including: setup.startShortcut) }
            }
            NidusGroupedPickerRow(title: "Turn it off",
                                    subtitle: setup.endShortcut == nil ? "Settings runs \(shortcutName(model.endShortcut))."
                                    : "Run when the session ends.") {
                Picker("Shortcut when it ends", selection: shortcut(\.endShortcut)) { shortcutChoices(including: setup.endShortcut) }
            }
        }
    }

    @ViewBuilder
    private func shortcutChoices(including chosen: String?) -> some View {
        Text("Uses Settings").tag(String?.none)
        Text("None").tag(String?.some(""))
        ForEach(shortcutOptions(including: chosen), id: \.self) { Text($0).tag(String?.some($0)) }
    }

    private func shortcutName(_ name: String?) -> String { name.map { "\u{201C}\($0)\u{201D}" } ?? "no Shortcut" }

    /// The library\u{2019}s Shortcuts, and a chosen one that has since been renamed
    /// or deleted, so the picker never loses its selection silently.
    private func shortcutOptions(including chosen: String?) -> [String] {
        guard let chosen, !chosen.isEmpty, !shortcutNames.contains(chosen) else { return shortcutNames }
        return [chosen] + shortcutNames
    }

    private func shortcut(_ keyPath: WritableKeyPath<FocusSetup, String?>) -> Binding<String?> {
        Binding(get: { setup?[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
    }

    /// Reads the library once, when the page appears. Never in a render.
    private func loadShortcuts() async {
        guard FocusShortcuts.isAvailable, !RenderSurfaces.isActive, !Demo.isActive else { return }
        shortcutNames = await FocusShortcuts.list()
    }

    // MARK: Exceptions

    private func exceptionsSection(_ setup: FocusSetup) -> some View {
        let live = model.categories.filter { setup.liveCategoryIDs(in: model.categories).contains($0.id) }
        let inherited = live.flatMap(\.websiteExceptions).count
        return NidusSettingsSection {
            settingsSectionHeader("Exceptions",
                                  detail: "Let one page through while the rest of a blocked website stays blocked.")
        } content: {
            NidusSettingsCard {
                line(.exceptions, "Pages let through",
                     summary: setup.mode == .allow ? "Block lists only" : setup.exceptionsSummary) {
                    if setup.mode == .allow {
                        Label("This setup allows only what its categories name, so there is nothing to make an exception to.",
                              systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        if inherited > 0 {
                            Text("Added to the \(inherited) its categories already let through.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        WebsiteExceptionsEditor(exceptions: exceptionsBinding, websites: live.flatMap(\.websites),
                                                sessionIsRunning: model.isActive, embedded: true)
                    }
                }
            }
        }
    }

    private var exceptionsBinding: Binding<[WebsiteException]> {
        Binding(get: { setup?.websiteExceptions ?? [] }, set: { list in update { $0.websiteExceptions = list } })
    }

    // MARK: Project and break

    private func projectAndBreakSection(_ setup: FocusSetup) -> some View {
        NidusSettingsSection {
            settingsSectionHeader("Project and break",
                                  detail: "What its sessions count toward, and the break after them. Each line can use the popover\u{2019}s or Settings\u{2019} choice instead.")
        } content: {
            NidusSettingsCard {
                // The popover offers a project only once there is one to pick;
                // so does this, unless the setup already has a choice to undo.
                if model.offersProjectPicker || setup.project != nil {
                    line(.project, "Project", summary: setup.projectSummary(in: model.projects)) { projectRows(setup) }
                }
                line(.breakLength, "Break", summary: setup.breakSummary) { breakRows(setup) }
                line(.breakRules, "Break rules",
                     summary: setup.breakRulesSummary(categories: model.categories,
                                                      appName: { BreakRulesNames.app($0, categories: model.categories) })) {
                    breakRulesRows(setup)
                }
            }
        }
    }

    /// How a setup's project is chosen: the popover\u{2019}s, none, or one of its own.
    private enum ProjectChoice: Hashable { case popover, none, own }

    private var projectChoice: Binding<ProjectChoice> {
        Binding(
            get: {
                switch setup?.project {
                case nil: return .popover
                case .noProject?: return .none
                case .project?: return .own
                }
            },
            set: { choice in
                update { setup in
                    switch choice {
                    case .popover: setup.project = nil
                    case .none: setup.project = .noProject
                    // The first project there is; the pop-up below changes it.
                    case .own: setup.project = FocusProject.active(model.projects).first.map { .project($0.id) } ?? .noProject
                    }
                }
            }
        )
    }

    private func projectRows(_ setup: FocusSetup) -> some View {
        Group {
            NidusGroupedPickerRow(title: "Counts toward",
                                    subtitle: setup.project == nil ? "Whichever project the popover has chosen when it starts."
                                    : "A project in the popover doesn\u{2019}t change it.") {
                Picker("Project", selection: projectChoice) {
                    Text("Uses the popover\u{2019}s").tag(ProjectChoice.popover)
                    Text("No project").tag(ProjectChoice.none)
                    if !FocusProject.active(model.projects).isEmpty || setup.project?.id != nil {
                        Text("A project").tag(ProjectChoice.own)
                    }
                }
            }
            if let id = setup.project?.id {
                NidusControlRow(title: "Project") {
                    FocusProjectPicker(
                        projects: model.projects,
                        selection: Binding(get: { id }, set: { chosen in
                            update { $0.project = chosen.map { .project($0) } ?? .noProject }
                        }),
                        edit: model.openProjects)
                }
            }
        }
    }

    private func breakRows(_ setup: FocusSetup) -> some View {
        NidusGroupedPickerRow(title: "Break after it",
                                subtitle: setup.breakMinutes == nil
                                ? "Settings\u{2019} break: \(model.breakMinutes == 0 ? "none" : FocusFormat.duration(minutes: model.breakMinutes))."
                                : "When it runs its full length, a break starts. Strict or not.") {
            Picker("Break after it", selection: breakMinutes) {
                Text("Uses Settings").tag(Int?.none)
                Text("No break").tag(Int?.some(0))
                ForEach(Self.breakChoices(including: setup.breakMinutes), id: \.self) { minutes in
                    Text(FocusFormat.duration(minutes: minutes)).tag(Int?.some(minutes))
                }
            }
        }
    }

    /// Settings\u{2019} lengths, and the setup\u{2019}s own if it is something else, so
    /// the pop-up never loses what it holds.
    static func breakChoices(including own: Int?) -> [Int] {
        let usual = NidusModel.breakChoices.filter { $0 > 0 }
        guard let own, own > 0, !usual.contains(own) else { return usual }
        return (usual + [own]).sorted()
    }

    private var breakMinutes: Binding<Int?> {
        Binding(get: { setup?.breakMinutes }, set: { value in update { $0.breakMinutes = value } })
    }

    private func breakRulesRows(_ setup: FocusSetup) -> some View {
        Group {
            NidusGroupedPickerRow(title: "During the break",
                                    subtitle: setup.breakRules == nil ? ruleLine(model.defaultBreakRules, "Settings")
                                    : "What stays blocked while the break runs. None chosen blocks nothing, even if Settings has rules.") {
                Picker("Break rules", selection: ownRules) {
                    Text("Uses Settings").tag(false)
                    Text("Its own rules").tag(true)
                }
            }
            if setup.breakRules != nil {
                BreakRulesEditor(rules: breakRulesBinding, categories: model.categories)
            }
            if effectiveBreakMinutes(setup) == 0 {
                Label("No break follows, so these rules aren\u{2019}t used.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func effectiveBreakMinutes(_ setup: FocusSetup) -> Int { setup.breakMinutes ?? model.breakMinutes }

    private func ruleLine(_ rules: BreakRules?, _ owner: String) -> String {
        guard let rules, let names = rules.blockedNames(categories: model.categories,
                                                        appName: { BreakRulesNames.app($0, categories: model.categories) }) else {
            return "\(owner) blocks nothing during a break."
        }
        return "\(owner) keeps \(BreakRules.list(names).text) blocked."
    }

    private var ownRules: Binding<Bool> {
        Binding(get: { setup?.breakRules != nil }, set: { own in update { $0.breakRules = own ? BreakRules() : nil } })
    }

    private var breakRulesBinding: Binding<BreakRules> {
        Binding(get: { setup?.breakRules ?? BreakRules() }, set: { rules in update { $0.breakRules = rules } })
    }

    // MARK: Changing the setup

    private func update(_ change: (inout FocusSetup) -> Void) {
        model.updateSetup(setupID, change)
    }

    private func allow(_ conflict: WorkspaceConflict) {
        let settingsApps = model.launchApps
        update { $0.allow(conflict, settingsLaunchApps: settingsApps) }
    }

    /// Where each resource is now. Read when the page appears and when the
    /// list changes, never while it draws.
    static func locate(_ resources: [WorkspaceResource]) -> [WorkspaceResource.ID: WorkspaceLocation] {
        let launcher = WorkspaceLauncher()
        return Dictionary(resources.map { ($0.id, launcher.locate($0)) }, uniquingKeysWith: { first, _ in first })
    }
}

// MARK: - The Open panel

/// The system Open panel for documents and folders. Only from a click.
@MainActor
enum WorkspaceChooser {
    static func choose(title: String, prompt: String, multiple: Bool = true, files: Bool = true,
                       folders: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseFiles = files
        panel.canChooseDirectories = folders
        panel.allowsMultipleSelection = multiple
        panel.canDownloadUbiquitousContents = false
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}
