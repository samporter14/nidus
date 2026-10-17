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
}

struct SetupWorkspaceSections: View {
    @ObservedObject var model: NidusModel
    let setupID: FocusSetup.ID

    @State private var opened: Set<SetupPart>
    @State private var locations: [WorkspaceResource.ID: WorkspaceLocation] = [:]
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
            let conflicts = setup.conflicts(in: model.categories)
            Group {
                startSection(setup, conflicts: conflicts)
                exceptionsSection(setup)
            }
            .task(id: setup.resources) { locations = Self.locate(setup.resources) }
            .task { await loadShortcuts() }
        }
    }

    // MARK: When it starts

    private func startSection(_ setup: FocusSetup, conflicts: [WorkspaceConflict]) -> some View {
        DropletSettingsSection {
            settingsSectionHeader("When it starts",
                                  detail: "Open what you work on and run your Shortcuts. Each line can use Settings\u{2019} choice instead.")
        } content: {
            DropletSettingsCard {
                attention(setup, conflicts: conflicts)
                line(.apps, "Apps", summary: setup.appsSummary) { appsRows(setup) }
                line(.documents, "Documents and folders", summary: documentsSummary(setup)) { documentRows(setup) }
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
            HStack(spacing: DroppySpacing.sm) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 12)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: DroppySpacing.md)
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
                if conflict.fix != nil {
                    Button("Allow only this page") { allow(conflict) }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Allow only \(conflict.page)")
                }
            } label: {
                Label("\(conflict.page) is blocked", systemImage: "exclamationmark.triangle")
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
            DropletGroupedPickerRow(title: "Open", subtitle: setup.launchApps == nil ? settingsAppsLine
                                    : "These open instead of the apps in Settings, the first in front. A session never blocks the apps it opened.") {
                Picker("Apps to open", selection: ownApps) {
                    Text("Uses Settings").tag(false)
                    Text("Its own list").tag(true)
                }
            }
            if let apps = setup.launchApps {
                ForEach(apps) { app in
                    DropletControlRow(title: app.name) {
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
                DropletControlRow(title: apps.isEmpty ? "Opens no apps" : "Add more",
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

    private func documentsSummary(_ setup: FocusSetup) -> String {
        let missing = setup.documents.filter { locations[$0.id]?.problem != nil }.count
        guard missing > 0 else { return setup.documentsSummary }
        let total = setup.documents.count
        return "\(total) \(total == 1 ? "item" : "items") \u{00B7} \(missing) missing"
    }

    private func documentRows(_ setup: FocusSetup) -> some View {
        Group {
            ForEach(setup.documents) { resource in
                let problem = locations[resource.id]?.problem
                LabeledContent {
                    HStack(spacing: DroppySpacing.sm) {
                        if problem != nil {
                            Button("Choose again\u{2026}") { chooseAgain(resource) }
                                .buttonStyle(.bordered)
                        }
                        removeButton(resource)
                    }
                } label: {
                    Label(resource.shownName, systemImage: resource.kind == .folder ? "folder" : "doc")
                    Text(problem.map { Self.problemTitle(for: resource, $0) } ?? Self.place(of: locations[resource.id]?.url ?? resource.path.map { URL(fileURLWithPath: $0) }))
                }
            }
            DropletControlRow(title: setup.documents.isEmpty ? "No documents or folders yet" : "Add more",
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
        guard !conflicts.isEmpty else { return setup.pagesSummary }
        let total = setup.pages.count
        return "\(total) \(total == 1 ? "page" : "pages") \u{00B7} \(conflicts.count) blocked"
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
            DropletControlRow(title: setup.pages.isEmpty ? "No web pages yet" : "Add another",
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
            DropletGroupedPickerRow(title: "Turn on a Focus",
                                    subtitle: setup.startShortcut == nil ? "Settings runs \(shortcutName(model.startShortcut))."
                                    : "Run when the session starts.") {
                Picker("Shortcut when it starts", selection: shortcut(\.startShortcut)) { shortcutChoices(including: setup.startShortcut) }
            }
            DropletGroupedPickerRow(title: "Turn it off",
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
        return DropletSettingsSection {
            settingsSectionHeader("Exceptions",
                                  detail: "Let one page through while the rest of a blocked website stays blocked.")
        } content: {
            DropletSettingsCard {
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

    // MARK: Changing the setup

    private func update(_ change: (inout FocusSetup) -> Void) {
        model.updateSetup(setupID, change)
    }

    private func allow(_ conflict: WorkspaceConflict) {
        update { $0.allow(conflict) }
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
