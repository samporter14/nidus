//
//  FocusProjectViews.swift
//  Nidus
//
//  What projects and resume notes look like: the picker the popover offers
//  once a project exists (reusable: a setup can show the same one), the
//  "pick up where you left off" row, the Projects list on the Stats page and
//  each project's own page. Native rows from Kit.swift; the popover stays
//  compact and shows nothing here until there is something to say.
//

import SwiftUI

// MARK: - The picker

/// A small pop-up for choosing a project, or none. Archived projects aren't
/// offered, but one that is already chosen stays shown (as archived) until
/// something else is picked, so a setup that points to one says so.
struct FocusProjectPicker: View {
    let projects: [FocusProject]
    @Binding var selection: UUID?
    /// "Edit projects…" at the foot of the menu; omitted when nil.
    var edit: (() -> Void)?

    private var current: ProjectLabel? {
        ProjectLabel.of(id: selection, storedName: nil, in: projects).flatMap { $0.state == .deleted ? nil : $0 }
    }

    var body: some View {
        Menu {
            Toggle(isOn: Binding(get: { current == nil }, set: { _ in selection = nil })) {
                Text("No project")
            }
            ForEach(FocusProject.active(projects)) { project in
                Toggle(isOn: Binding(get: { selection == project.id }, set: { _ in selection = project.id })) {
                    Label(project.displayName, systemImage: "folder")
                }
            }
            if let edit {
                Divider()
                Button("Edit projects\u{2026}", action: edit)
            }
        } label: {
            HStack(spacing: NidusSpacing.xs) {
                Image(systemName: "folder")
                Text(verbatim: current?.text ?? "No project").lineLimit(1)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help("The project this session counts toward")
        .accessibilityLabel("Project")
        .accessibilityValue(current?.text ?? "None")
    }
}

/// The popover's row for it: nothing at all until there is a project to pick.
struct FocusProjectPickerRow: View {
    @ObservedObject var model: NidusModel

    /// Shown once at least one project isn't archived: archived ones aren't
    /// offered, so a list of only those has nothing to pick.
    static func isVisible(projects: [FocusProject]) -> Bool {
        !FocusProject.active(projects).isEmpty
    }

    var body: some View {
        if model.offersProjectPicker {
            HStack(spacing: NidusSpacing.sm) {
                FocusProjectPicker(projects: model.projects, selection: model.binding(\.selectedProjectID),
                                   edit: model.openProjects)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Pick up where you left off

/// The newest note nobody has dismissed, as one row in the idle popover.
struct ResumePopoverRow: View {
    @ObservedObject var model: NidusModel

    var body: some View {
        if let note = model.newestResumeNote {
            ResumeNoteRow(model: model, note: note, compact: true)
        }
    }
}

/// A note with Resume and Dismiss. `compact` is the popover's row (the step
/// over a quiet line saying where it is from); the other is a row of a
/// project's page.
struct ResumeNoteRow: View {
    @ObservedObject var model: NidusModel
    let note: ResumeNote
    var compact = false

    private var label: ProjectLabel? { note.projectLabel(in: model.projects) }
    private var busyReason: String? { SessionGate.busyReason(isActive: model.isActive, isOnBreak: model.isOnBreak) }
    private var notice: String? { model.resumeNotice.flatMap { $0.noteID == note.id ? $0.text : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: NidusSpacing.sm) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: quietLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: NidusSpacing.xs) {
                        Text(verbatim: note.headline)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let resource = note.resource {
                            Image(systemName: ResumeResources.symbol(for: resource.kind))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .help("Opens \(resource.displayName) when you resume")
                                .accessibilityLabel("Opens \(resource.displayName)")
                        }
                    }
                }
                Spacer(minLength: NidusSpacing.sm)
                Button("Resume") { model.resume(note) }
                    .buttonStyle(.bordered)
                    .controlSize(compact ? .small : .regular)
                    .fixedSize()
                    .disabled(busyReason != nil)
                    .help(busyReason ?? resumeHelp)
                    .accessibilityLabel("Resume: \(note.headline)")
                    .accessibilityHint(busyReason ?? resumeHelp)
                Button {
                    model.dismissResumeNote(note.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dismiss this note")
                .accessibilityLabel("Dismiss note: \(note.headline)")
            }
            if let reason = notice ?? (compact ? nil : busyReason) {
                Text(verbatim: reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, compact ? NidusSpacing.md : 0)
        .padding(.vertical, compact ? NidusSpacing.sm : 2)
        .background {
            if compact {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AdaptiveColors.surfaceCardFill)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var resumeHelp: String {
        let opens = note.resource.map { " and opens \($0.displayName)" } ?? ""
        return "Starts a session for \u{201C}\(note.sessionGoal)\u{201D}\(opens)"
    }

    /// Where the note is from, in a few words.
    private var quietLine: String {
        if compact {
            return ["Pick up where you left off", label?.text].compactMap { $0 }.joined(separator: " \u{B7} ")
        }
        var parts: [String] = []
        if !note.text.isEmpty, !note.goal.isEmpty { parts.append("After \u{201C}\(note.goal)\u{201D}") }
        parts.append(note.createdAt.formatted(.dateTime.day().month(.abbreviated)))
        if let resource = note.resource { parts.append(resource.displayName) }
        return parts.joined(separator: " \u{B7} ")
    }
}

// MARK: - The Projects list, on the Stats page

struct FocusProjectsSection: View {
    @ObservedObject var model: NidusModel
    @State private var newName = ""
    @State private var problem: String?

    var body: some View {
        let roster = model.projectRoster
        NidusSettingsSection {
            settingsSectionHeader("Projects",
                                  detail: "Count sessions toward what they\u{2019}re for. Pick one in the popover before you start.")
        } content: {
            NidusSettingsCard {
                ForEach(roster.live) { row in
                    NidusSettingsPageLink(
                        row.project.isArchived ? "\(row.project.displayName) (archived)" : row.project.displayName,
                        subtitle: subtitle(row.summary, notes: ResumeNote.waiting(for: row.project.id, in: model.resumeNoteList).count),
                        page: NidusModel.projectPagePrefix + row.project.id.uuidString
                    ) {
                        CategoryTile(symbol: row.project.isArchived ? "archivebox" : "folder")
                    }
                }
                ForEach(roster.deleted, id: \.projectID) { summary in
                    let label = ProjectLabel.of(id: summary.projectID, storedName: summary.recordedName, in: model.projects)
                    HStack(spacing: 10) {
                        CategoryTile(symbol: "folder.badge.minus")
                            .opacity(0.6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: label?.text ?? ProjectLabel.unnamed)
                                .foregroundStyle(.secondary)
                            Text(verbatim: subtitle(summary, notes: 0))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                NidusControlRow(title: "New project", infoTip: problem) {
                    HStack(spacing: NidusSpacing.sm) {
                        TextField("Name", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                            .labelsHidden()
                            .onSubmit(add)
                            .onChange(of: newName) { _, _ in problem = nil }
                            .accessibilityLabel("New project name")
                        Button("Add", action: add)
                            .buttonStyle(.bordered)
                            .disabled(FocusProject.cleaned(newName).isEmpty)
                    }
                }
            }
        }
    }

    private func add() {
        switch model.addProject(named: newName) {
        case .added: newName = ""; problem = nil
        case .blank: problem = "Give it a name."
        case .duplicate(let same): problem = "\u{201C}\(same.displayName)\u{201D} already exists."
        }
    }

    /// "3 hr 20 min · 8 sessions · 2 notes".
    private func subtitle(_ summary: ProjectSummary, notes: Int) -> String {
        var parts: [String] = []
        if summary.sessionCount == 0 {
            parts.append("No sessions yet")
        } else {
            parts.append(FocusFormat.long(summary.focused))
            parts.append("\(summary.sessionCount) \(summary.sessionCount == 1 ? "session" : "sessions")")
        }
        if notes > 0 { parts.append("\(notes) \(notes == 1 ? "note" : "notes")") }
        return parts.joined(separator: " \u{B7} ")
    }
}

// MARK: - One project

struct FocusProjectPage: View {
    @ObservedObject var model: NidusModel
    let projectID: UUID
    @State private var goal = ""
    @State private var startMessage: String?
    @State private var confirmingDelete = false

    private var project: FocusProject? { model.project(projectID) }

    var body: some View {
        NidusSettingsPage {
            if let project {
                let summary = model.projectSummary(for: projectID)
                details(project)
                totals(summary)
                start(project)
                notes()
                unfinished(summary)
                recent(summary)
                removal(project)
            } else {
                Text("This project is gone.")
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Delete \u{201C}\(project?.displayName ?? "this project")\u{201D}?", isPresented: $confirmingDelete) {
            Button("Delete project", role: .destructive) { model.deleteProject(projectID) }
        } message: {
            Text("It leaves your list. Sessions already recorded keep its name, shown as \u{201C}\(project?.displayName ?? "Name") (deleted)\u{201D}, and notes keep their text. Nothing in your history is changed.")
        }
    }

    // MARK: Name and archive

    private func details(_ project: FocusProject) -> some View {
        NidusSettingsCard {
            NidusControlRow(title: "Name") {
                TextField("Name", text: Binding(get: { project.name }, set: { model.renameProject(projectID, to: $0) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .labelsHidden()
            }
            NidusToggleRow(title: "Archived",
                             subtitle: "Left out of the popover\u{2019}s picker and new sessions. Its history and notes are kept.",
                             isOn: Binding(get: { project.isArchived }, set: { model.setProjectArchived(projectID, $0) }))
        }
    }

    // MARK: Numbers

    private func totals(_ summary: ProjectSummary) -> some View {
        NidusSettingsSection {
            settingsSectionHeader("Time", detail: model.recordsHistory
                ? "Worked out from your history. Pauses and breaks aren\u{2019}t counted."
                : "History is off, so new sessions aren\u{2019}t counted toward projects.")
        } content: {
            NidusSettingsCard {
                NidusControlRow(title: "Time focused") { NidusValuePill(text: FocusFormat.long(summary.focused)) }
                NidusControlRow(title: "Sessions") {
                    NidusValuePill(text: summary.sessionCount == 0
                                     ? "None yet" : "\(summary.sessionCount), \(summary.completedCount) completed")
                }
                NidusControlRow(title: "Unfinished goals",
                                  infoTip: "Goals you answered \u{201C}Not yet\u{201D} to and haven\u{2019}t finished since.") {
                    NidusValuePill(text: "\(summary.unfinished.count)")
                }
            }
        }
    }

    // MARK: Starting

    private func start(_ project: FocusProject) -> some View {
        let refusal = model.startRefusal(for: project)
        return NidusSettingsSection {
            settingsSectionHeader("Start a session", detail: "Uses the length and categories chosen in the popover.")
        } content: {
            NidusSettingsCard {
                NidusControlRow(title: "Goal", infoTip: "Optional.") {
                    TextField("None", text: $goal)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .labelsHidden()
                        .onSubmit { begin(project) }
                }
                NidusControlRow(title: "Start", infoTip: refusal ?? startMessage) {
                    Button("Start") { begin(project) }
                        .buttonStyle(.borderedProminent)
                        .tint(FocusPalette.clay)
                        .disabled(refusal != nil)
                        .accessibilityHint(refusal ?? "Starts a session counted toward \(project.displayName)")
                }
            }
        }
    }

    private func begin(_ project: FocusProject) {
        startMessage = model.startSession(for: project, goal: goal)
        if startMessage == nil { goal = "" }
    }

    // MARK: Notes and sessions

    @ViewBuilder
    private func notes() -> some View {
        let waiting = ResumeNote.waiting(for: projectID, in: model.resumeNoteList)
        if !waiting.isEmpty {
            NidusSettingsSection {
                settingsSectionHeader("Notes", detail: "Next steps you wrote down. Resume starts a session for one.")
            } content: {
                NidusSettingsCard {
                    ForEach(waiting) { note in
                        ResumeNoteRow(model: model, note: note)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func unfinished(_ summary: ProjectSummary) -> some View {
        if !summary.unfinished.isEmpty {
            NidusSettingsSection {
                settingsSectionHeader("Unfinished goals")
            } content: {
                NidusSettingsCard {
                    ForEach(summary.unfinished) { entry in
                        NidusControlRow(title: entry.goal) {
                            NidusValuePill(text: entry.start.formatted(.dateTime.day().month(.abbreviated)))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recent(_ summary: ProjectSummary) -> some View {
        if !summary.recent.isEmpty {
            NidusSettingsSection {
                settingsSectionHeader("Recent sessions")
            } content: {
                NidusSettingsCard {
                    ForEach(summary.recent) { entry in
                        NidusControlRow(title: entry.goal.isEmpty ? "No goal" : entry.goal) {
                            NidusValuePill(text: "\(FocusFormat.long(entry.focused)) \u{B7} \(entry.start.formatted(.dateTime.day().month(.abbreviated)))")
                        }
                    }
                }
            }
        }
    }

    // MARK: Removing

    private func removal(_ project: FocusProject) -> some View {
        NidusSettingsCard {
            NidusControlRow(title: "Delete project",
                              infoTip: "Takes it out of your list only. Past sessions keep its name.") {
                Button("Delete\u{2026}", role: .destructive) { confirmingDelete = true }
                    .buttonStyle(.bordered)
            }
        }
    }
}
