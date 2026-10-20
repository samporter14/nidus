//
//  ResumeNotes.swift
//  Nidus
//
//  Resume notes (Core/ResumeNote.swift): the file they are kept in, the
//  next-step field on the wrap-up card, and the model's side of picking one
//  up again. docs/design-0.4.md, "Resume notes".
//
//  `resume-notes.json` sits in Nidus's folder beside the history, is written
//  atomically, and is read note by note: one that doesn't decode is dropped,
//  not the file. It is not history: it is kept when sessions aren't being
//  recorded, because the person typed it. Clear History clears it too.
//

import AppKit
import SwiftUI

// MARK: - The file

@MainActor
final class ResumeNoteStore {
    struct File: Codable {
        var version = 1
        var notes: [ResumeNote]

        init(version: Int = 1, notes: [ResumeNote]) {
            self.version = version
            self.notes = notes
        }

        /// Note by note, as the history file is read.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
            notes = try c.decode(LossyArray<ResumeNote>.self, forKey: .notes).elements
        }

        enum CodingKeys: String, CodingKey { case version, notes }
    }

    /// Past this, the oldest dismissed notes go first, then the oldest.
    static let limit = 200
    static let fileName = "resume-notes.json"

    let url: URL
    private let persistence: PersistenceCoordinator?
    private(set) var notes: [ResumeNote] = []

    init(url: URL, persistence: PersistenceCoordinator? = nil) {
        self.url = url
        self.persistence = persistence
        guard let data = try? Data(contentsOf: url) else { return }
        if let file = try? JSONDecoder().decode(File.self, from: data) {
            notes = file.notes.filter(\.hasContent)
        } else {
            // Not a notes file Nidus can read. Starting empty would write
            // over it at the next note, so it is put aside first, intact.
            FocusHistory.setAside(url)
        }
    }

    func note(_ id: UUID) -> ResumeNote? { notes.first { $0.id == id } }

    func add(_ note: ResumeNote) {
        notes.removeAll { $0.id == note.id }
        notes.append(note)
        prune()
        save()
    }

    /// Changes one note. Never touches anything but notes: not the history,
    /// and so never a "did you finish?" answer.
    @discardableResult
    func update(_ id: UUID, _ change: (inout ResumeNote) -> Void) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        change(&notes[index])
        save()
        return true
    }

    @discardableResult
    func dismiss(_ id: UUID, at date: Date = Date()) -> Bool {
        update(id) { $0.dismissedAt = $0.dismissedAt ?? date }
    }

    @discardableResult
    func remove(_ id: UUID) -> Bool {
        guard notes.contains(where: { $0.id == id }) else { return false }
        notes.removeAll { $0.id == id }
        save()
        return true
    }

    func clear() {
        notes.removeAll()
        if let persistence { persistence.remove(url, label: "Resume notes") }
        else { try? FileManager.default.removeItem(at: url) }
    }

    private func prune() {
        while notes.count > Self.limit {
            let oldestDismissed = notes.indices.filter { notes[$0].isDismissed }.min { notes[$0].createdAt < notes[$1].createdAt }
            let oldest = notes.indices.min { notes[$0].createdAt < notes[$1].createdAt }
            guard let drop = oldestDismissed ?? oldest else { break }
            notes.remove(at: drop)
        }
    }

    private func save() {
        if let persistence {
            let snapshot = notes
            persistence.write(to: url, label: "Resume notes") { try Self.encode(snapshot) }
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Self.encode(notes).write(to: url, options: .atomic)
    }

    nonisolated static func encode(_ notes: [ResumeNote]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(File(notes: notes))
    }
}

// MARK: - The next-step field

/// The note being written on the wrap-up card, after "Did you finish?" is
/// answered (either way) or at once when sessions aren't recorded. Every edit
/// is kept as it is made, so a card that goes away mid-sentence loses
/// nothing; emptying both the step and the link takes the note away again.
@MainActor @Observable
final class NextStepSession {
    /// What the session it follows says about it.
    struct Seed: Equatable, Sendable {
        var goal: String
        var projectID: UUID?
        var projectName: String?
        /// The history entry it is written after; nil when none was recorded.
        var entryID: UUID?
    }

    let seed: Seed
    /// Sessions aren't being recorded: the card says only a note is kept.
    let historyIsOff: Bool
    /// As typed (not trimmed, so a space between two words survives typing).
    private(set) var text = ""
    private(set) var resource: WorkspaceResource?
    private(set) var noteID: UUID?
    /// Asks the card's field to take the keyboard, from the menu bar.
    var focusRequests = 0

    @ObservationIgnored private let store: ResumeNoteStore
    @ObservationIgnored private let now: () -> Date
    /// The model's: refresh the card's timer, tell the popover.
    @ObservationIgnored var onChange: () -> Void = {}
    /// The step once typing has paused, or the card is done with: the note's
    /// text, nil when there is none. Plaque is told here, so a reader of the
    /// file sees a sentence and not every letter of it.
    @ObservationIgnored var onSettled: (String?) -> Void = { _ in }
    @ObservationIgnored private let settleDelay: Duration
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var lastSettled: String?

    init(seed: Seed, historyIsOff: Bool, store: ResumeNoteStore, now: @escaping () -> Date = Date.init,
         settleDelay: Duration = .seconds(1.5)) {
        self.seed = seed
        self.historyIsOff = historyIsOff
        self.store = store
        self.now = now
        self.settleDelay = settleDelay
    }

    /// Reports the step as it stands, if it changed since last reported, and
    /// stops waiting for typing to pause.
    func settleNow() {
        settleTask?.cancel()
        settleTask = nil
        let kept = ResumeNote.clean(text)
        let step = kept.isEmpty ? nil : kept
        guard step != lastSettled else { return }
        lastSettled = step
        onSettled(step)
    }

    private func settleLater() {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self, settleDelay] in
            try? await Task.sleep(for: settleDelay)
            guard !Task.isCancelled else { return }
            self?.settleNow()
        }
    }

    /// The session this follows was brought back (Undo): nothing is kept.
    func discard() {
        settleTask?.cancel()
        settleTask = nil
        if let id = noteID { store.remove(id) }
        noteID = nil
        text = ""
        resource = nil
        onChange = {}
        onSettled = { _ in }
    }

    var isSaved: Bool { noteID.flatMap { store.note($0) } != nil }

    func setText(_ raw: String) {
        let capped = String(raw.components(separatedBy: .newlines).joined(separator: " ").prefix(ResumeNote.textLimit))
        guard capped != text else { return }
        text = capped
        persist()
    }

    func setResource(_ new: WorkspaceResource?) {
        guard new != resource else { return }
        resource = new
        persist()
    }

    private func persist() {
        defer {
            onChange()
            settleLater()
        }
        let kept = ResumeNote.clean(text)
        if kept.isEmpty, resource == nil {
            if let id = noteID { store.remove(id) }
            noteID = nil
            return
        }
        if let id = noteID, store.update(id, { $0.text = kept; $0.resource = resource }) { return }
        // First time, or the note was cleared away behind this card.
        let note = ResumeNote(id: noteID ?? UUID(), text: kept, resource: resource, goal: seed.goal,
                              projectID: seed.projectID, projectName: seed.projectName,
                              entryID: seed.entryID, createdAt: now())
        store.add(note)
        noteID = note.id
    }

    /// The words under the field while sessions aren't being recorded.
    var historyOffCaption: String {
        isSaved ? "Saved as a note. Session history is off." : "Session history is off. Only this note is kept."
    }
}

struct NextStepRow: View {
    let step: NextStepSession
    var chooseDocument: () -> Void = {}
    var addWebAddress: () -> Void = {}
    var done: () -> Void = {}
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: NidusSpacing.sm) {
                TextField("What\u{2019}s the next step?", text: Binding(get: { step.text }, set: { step.setText($0) }))
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(done)
                    .onKeyPress(.escape) {
                        done()
                        return .handled
                    }
                    .help("Optional. Up to \(ResumeNote.textLimit) characters. Return saves it, Escape closes the card.")
                    .accessibilityLabel("Next step, optional")
                linkMenu
                Button("Done", action: done)
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .accessibilityLabel(step.isSaved ? "Done, the note is saved" : "Done")
            }
            if step.historyIsOff {
                Text(verbatim: step.historyOffCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.surfaceSecondaryText)
                    .lineLimit(1)
            }
        }
        .onChange(of: step.focusRequests) { _, _ in fieldFocused = true }
    }

    private var linkMenu: some View {
        Menu {
            Button("Choose a document or folder\u{2026}", action: chooseDocument)
            Button("Add a web address\u{2026}", action: addWebAddress)
            if step.resource != nil {
                Divider()
                Button("Remove the link", role: .destructive) { step.setResource(nil) }
            }
        } label: {
            if let resource = step.resource {
                // An image and a title, not a Label: a menu draws only the title of that.
                HStack(spacing: NidusSpacing.xs) {
                    Image(systemName: ResumeResources.symbol(for: resource.kind))
                    Text(verbatim: resource.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 130)
            } else {
                Image(systemName: "link")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(step.resource.map { "Opens \($0.displayName) when you pick this up" } ?? "Add a document, folder or web page to open with it")
        .accessibilityLabel(step.resource.map { "Link: \($0.displayName)" } ?? "Add a link, optional")
    }
}

// MARK: - The model's side

extension NidusModel {
    /// The card's timer, once a note is being written: long enough to type.
    var noteLinger: TimeInterval { FinishReply.noteLinger }

    var resumeNoteList: [ResumeNote] { resumeNotes?.notes ?? [] }

    /// The one the idle popover offers.
    var newestResumeNote: ResumeNote? { ResumeNote.newestUndismissed(in: resumeNoteList) }

    // MARK: Writing one

    /// The field for the session that just ended, or nil when a note isn't
    /// offered: no goal to follow up, or a session too short to count.
    func beginNextStep(for final: SessionState, entry: SessionEntry?) -> NextStepSession? {
        guard let store = resumeNotes, (final.focusedTime ?? 0) >= SessionEntry.minimumFocus,
              !final.plan.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let step = NextStepSession(
            seed: .init(goal: final.plan.goal, projectID: final.plan.projectID, projectName: final.plan.projectName, entryID: entry?.id),
            historyIsOff: !recordsHistory, store: store)
        step.onChange = { [weak self] in self?.nextStepDidChange() }
        // Plaque's finished page shows the step (when sharing is on).
        step.onSettled = { [weak self] text in self?.notePlaqueNextStep(text) }
        return step
    }

    private func nextStepDidChange() {
        // Typing keeps the card up; the popover learns of a new note.
        host?.hud.refresh(id: Self.completedHUDID, duration: noteLinger)
        objectWillChange.send()
    }

    /// Done, or Return in the field: the card has nothing more to ask.
    func finishNextStep() {
        cards.nextStep?.settleNow()
        if let step = cards.nextStep, step.isSaved {
            let said = step.historyIsOff ? "Saved as a note. Session history is off." : "Saved as a note."
            host?.hud.refresh(id: Self.completedHUDID, duration: 1.2, announcing: said)
        } else {
            host?.hud.dismiss(id: Self.completedHUDID)
        }
    }

    /// Whether "Add a next step" can be offered in the menu: the card is up
    /// and its field is showing (the question, if it asked one, is answered).
    var canAddNextStep: Bool {
        cards.nextStep != nil && pendingFinish == nil && host?.hud.isShowing(id: Self.completedHUDID) == true
    }

    /// From the menu bar: puts the keyboard in the card's field. Only ever
    /// from a menu item the person chose, never on its own.
    func focusNextStep() {
        guard canAddNextStep, let step = cards.nextStep else { return }
        host?.hud.refresh(id: Self.completedHUDID, duration: noteLinger)
        host?.hud.makeKey(id: Self.completedHUDID)
        step.focusRequests += 1
    }

    func chooseNextStepDocument() {
        guard let step = cards.nextStep else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the document or folder to open when you pick this up."
        panel.prompt = "Choose"
        // The card waits while the panel is up.
        host?.hud.refresh(id: Self.completedHUDID, duration: 300)
        let chosen: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self, weak step] response in
            if response == .OK, let url = panel.url, let resource = ResumeResources.resource(forFile: url) {
                step?.setResource(resource)
            }
            self?.host?.hud.refresh(id: Self.completedHUDID, duration: self?.noteLinger ?? 20)
        }
        NSApp.activate()
        panel.begin(completionHandler: chosen)
    }

    func addNextStepWebAddress() {
        guard let step = cards.nextStep else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "example.org/page"
        let alert = NSAlert()
        alert.messageText = "Add a web address"
        alert.informativeText = "An http or https address that opens in your browser when you pick this up."
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        host?.hud.refresh(id: Self.completedHUDID, duration: 300)
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            if let page = ResumeResources.webPage(from: field.stringValue) {
                step.setResource(page)
            } else {
                NSSound.beep()
            }
        }
        host?.hud.refresh(id: Self.completedHUDID, duration: noteLinger)
    }

    // MARK: Picking one up

    /// Opens a note's link, now that its session has started. A bookmark
    /// that had gone stale is saved again fresh, so a moved file keeps being
    /// found.
    private func openLink(of note: ResumeNote, _ resource: WorkspaceResource) -> ResumeLinkResult {
        switch ResumeResources.resolve(resource) {
        case .missing(let name):
            return .missing(name)
        case .page(let url):
            return urlOpener(url) ? .opened : .failed(resource.displayName)
        case .file(let url, let refreshed):
            if let refreshed { resumeNotes?.update(note.id) { $0.resource = refreshed } }
            return urlOpener(url) ? .opened : .failed(resource.displayName)
        }
    }

    /// Resume, from the popover or a project's page. Never replaces a session
    /// or break that is on; says why instead. Opens the note's link only
    /// here, on this click, and only once the session has started.
    @discardableResult
    func resume(_ note: ResumeNote) -> ResumeRunner.Outcome {
        // The runner lives for this one call, so holding self is no cycle.
        let runner = ResumeRunner(
            isActive: { [self] in isActive },
            isOnBreak: { [self] in isOnBreak },
            projects: { [self] in projects },
            start: { [self] request in startSession(request) },
            open: { [self] resource in openLink(of: note, resource) },
            dismiss: { [self] id in dismissResumeNote(id) })
        let outcome = runner.resume(note)
        switch outcome {
        case .refused(let reason):
            resumeNotice = ResumeNotice(noteID: note.id, text: reason)
        case .couldNotStart:
            resumeNotice = ResumeNotice(noteID: note.id, text: "Nothing started. Pick a category with something to block.")
        case .started(let link):
            resumeNotice = nil
            switch link {
            case .missing(let name)?: presentLinkNotice("Couldn\u{2019}t find \(name)", detail: "Your session started without it.")
            case .failed(let name)?: presentLinkNotice("Couldn\u{2019}t open \(name)", detail: "Your session started without it.")
            default: break
            }
        }
        return outcome
    }

    /// Dismissing keeps the note's record out of sight; the session it
    /// followed is not touched.
    func dismissResumeNote(_ id: UUID) {
        resumeNotes?.dismiss(id)
        if resumeNotice?.noteID == id { resumeNotice = nil }
        objectWillChange.send()
    }

    private func presentLinkNotice(_ title: String, detail: String) {
        guard let host else { return }
        let request = HUDRequest(id: Self.linkNoticeHUDID, duration: 6, accessibilityLabel: "\(title). \(detail)") { [weak self] in
            FocusNoticeCard(symbol: "exclamationmark.triangle", variants: [
                .init(title: Text(verbatim: title), detail: Text(verbatim: detail), button: "OK"),
            ]) { self?.host?.hud.dismiss(id: Self.linkNoticeHUDID) }
        }
        host.hud.present(request)
    }

    static let linkNoticeHUDID = "focus.resume-link"
}

/// Why a Resume did nothing, shown beside the note it was pressed on.
struct ResumeNotice: Equatable {
    var noteID: UUID
    var text: String
}
