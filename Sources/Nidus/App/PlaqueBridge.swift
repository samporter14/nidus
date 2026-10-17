//
//  PlaqueBridge.swift
//  Nidus
//
//  Telling Plaque about focus, when the person turns it on (Settings >
//  General > Plaque). Nidus writes `plaque-focus.json` in its own folder and
//  says so on this Mac (`local.sam.nidus.plaque-focus`); Plaque reads it,
//  draws a page and sends it to a reader only when someone presses Send
//  there. Nothing here reaches the network. `focus.json` and its notice,
//  which other Solanum apps read, are untouched.
//
//  docs/design-0.4.md, "Plaque focus display", has the file's format.
//

import Foundation

extension NidusModel.Key {
    static let plaqueFocus = "plaqueFocus"
    static let plaqueFocusText = "plaqueFocusText"
    static let plaqueFocusRevision = "plaqueFocusRevision"
}

/// Writes the snapshot: at once on a change, again every few minutes while
/// something is on so a reader of the file can tell Nidus is still there, and
/// never twice for the same state between those.
@MainActor
final class PlaqueBridge {
    static let notification = Notification.Name("local.sam.nidus.plaque-focus")
    static let fileName = "plaque-focus.json"

    let fileURL: URL
    private let now: () -> Date
    private let notify: () -> Void
    private let loadRevision: () -> Int
    private let saveRevision: (Int) -> Void
    private(set) var lastWritten: PlaqueFocusSnapshot?

    /// The session that just finished, shown as finished for a while.
    struct Finished: Equatable {
        var sessionID: String
        var startedAt: Date
        var at: Date
        var goal: String
        var project: String?
        var nextStep: String?
    }
    private(set) var finished: Finished?

    init(directory: URL, now: @escaping () -> Date = Date.init,
         notify: @escaping () -> Void = { PlaqueBridge.postNotice() },
         loadRevision: @escaping () -> Int = { 0 }, saveRevision: @escaping (Int) -> Void = { _ in }) {
        fileURL = directory.appendingPathComponent(Self.fileName)
        self.now = now
        self.notify = notify
        self.loadRevision = loadRevision
        self.saveRevision = saveRevision
    }

    static func postNotice() {
        DistributedNotificationCenter.default().postNotificationName(notification, object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
    }

    /// Writes `input` if sharing is on and it says something new, or the
    /// heartbeat is due. With sharing off, removes the file once.
    func publish(_ input: PlaqueFocusSnapshot.Input, enabled: Bool, sharesText: Bool) {
        guard enabled else { return disable() }
        let time = now()
        let candidate = PlaqueFocusSnapshot.make(input, revision: loadRevision() + 1, now: time, sharesText: sharesText)
        if let last = lastWritten, last.sameContent(as: candidate) {
            let resting = candidate.state == .idle || candidate.state == .offline
            if resting || time.timeIntervalSince(last.updatedAt) < PlaqueFocusSnapshot.heartbeat { return }
        }
        guard let data = candidate.encoded() else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Atomic: Plaque never reads half a file.
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return
        }
        saveRevision(candidate.revision)
        lastWritten = candidate
        notify()
    }

    /// Sharing turned off: the file goes, with what it said, and Plaque is
    /// told. A page already sent to a reader stays there; Settings says so.
    func disable() {
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        guard exists || lastWritten != nil else { return }
        try? FileManager.default.removeItem(at: fileURL)
        lastWritten = nil
        notify()
    }

    func noteFinished(_ finished: Finished?) { self.finished = finished }

    /// Once "finished" has been shown long enough, `action` writes idle. The
    /// clock is stopped between sessions, so this is timed on its own; a
    /// newer finish, or quitting, cancels it.
    private var lingerTask: Task<Void, Never>?

    func afterFinishedLinger(_ action: @escaping @MainActor () -> Void) {
        lingerTask?.cancel()
        lingerTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(PlaqueFocusSnapshot.finishedLinger + 1))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancelPending() {
        lingerTask?.cancel()
        lingerTask = nil
    }

    /// The finished session, while it is still recent enough to show.
    func recentFinish(at time: Date) -> Finished? {
        guard let finished, time.timeIntervalSince(finished.at) < PlaqueFocusSnapshot.finishedLinger else { return nil }
        return finished
    }
}

// MARK: - The model's side

extension NidusModel {
    /// Off by default. Writes the snapshot Plaque reads; nothing leaves the Mac.
    var sharesFocusWithPlaque: Bool {
        get { preference(Key.plaqueFocus, default: false) }
        set {
            setPreference(newValue, Key.plaqueFocus)
            publishPlaqueFocus()
        }
    }

    /// Off by default, and only with sharing on: the goal, project and next
    /// step go in the file too.
    var sharesFocusTextWithPlaque: Bool {
        get { preference(Key.plaqueFocusText, default: false) }
        set {
            setPreference(newValue, Key.plaqueFocusText)
            publishPlaqueFocus()
        }
    }

    func makePlaqueBridge(directory: URL) -> PlaqueBridge {
        PlaqueBridge(directory: directory,
                     loadRevision: { [weak self] in self?.preference(Key.plaqueFocusRevision, default: 0) ?? 0 },
                     saveRevision: { [weak self] in self?.host?.preferences.setValueQuietly($0, forKey: Key.plaqueFocusRevision) })
    }

    /// Called wherever `focus.json` is: on every session change, on the
    /// clock's tick, and on quit. Demos and renders write nothing.
    func publishPlaqueFocus(quitting: Bool = false) {
        guard !Demo.isActive, let plaqueBridge else { return }
        plaqueBridge.publish(plaqueFocusInput(quitting: quitting, now: Date()),
                             enabled: sharesFocusWithPlaque, sharesText: sharesFocusTextWithPlaque)
    }

    /// A session ended: a completed one shows as finished for a while (with
    /// its next step, when one is written), anything else goes straight to
    /// idle. The clock stops between sessions, so the turn to idle is timed.
    func notePlaqueSessionEnded(_ reason: SessionEndReason, _ final: SessionState) {
        guard let plaqueBridge else { return }
        guard reason == .completed, engine?.isOnBreak != true else {
            plaqueBridge.noteFinished(nil)
            return
        }
        plaqueBridge.noteFinished(PlaqueBridge.Finished(
            sessionID: PlaqueFocusSnapshot.sessionID(startedAt: final.startedAt), startedAt: final.startedAt,
            at: Date(), goal: final.plan.goal, project: final.plan.projectName, nextStep: nil))
        plaqueBridge.afterFinishedLinger { [weak self] in self?.publishPlaqueFocus() }
    }

    /// The next step written on the finish card, for a finished snapshot.
    func notePlaqueNextStep(_ text: String?) {
        guard let plaqueBridge, var finished = plaqueBridge.finished else { return }
        finished.nextStep = text
        plaqueBridge.noteFinished(finished)
        publishPlaqueFocus()
    }

    /// Nidus's state as the snapshot needs it.
    func plaqueFocusInput(quitting: Bool, now: Date) -> PlaqueFocusSnapshot.Input {
        guard !quitting, let engine else { return .init(phase: .offline) }
        let sequence = engine.sequence
        if let session = engine.session {
            let plan = session.plan
            let id = PlaqueFocusSnapshot.sessionID(startedAt: session.startedAt)
            let paused = engine.isPaused
            let end: Date? = plan.duration == nil ? nil : now.addingTimeInterval(engine.remaining ?? 0)
            return .init(phase: paused ? .paused(remaining: engine.remaining ?? 0) : .focusing(endsAt: end),
                         sessionID: id, startedAt: session.startedAt, strict: plan.strict,
                         next: paused ? Self.plaqueNext(after: session, sequence: sequence, endsAt: nil, settingsBreak: engine.breakLength,
                                                        fixedEnd: isFixedEndSession(session))
                                      : Self.plaqueNext(after: session, sequence: sequence, endsAt: end, settingsBreak: engine.breakLength,
                                                        fixedEnd: isFixedEndSession(session)),
                         sequence: Self.plaqueSequence(sequence),
                         goal: plan.goal, project: plan.projectName)
        }
        if let pause = engine.breakState {
            let minutes = pause.plan.duration.map { Int(($0 / 60).rounded()) }
            return .init(phase: .onBreak(endsAt: pause.endsAt),
                         sessionID: PlaqueFocusSnapshot.sessionID(startedAt: pause.endsAt.addingTimeInterval(-pause.length)),
                         startedAt: pause.endsAt.addingTimeInterval(-pause.length),
                         next: .init(kind: .block, startsAt: pause.endsAt, minutes: minutes),
                         sequence: Self.plaqueSequence(sequence),
                         goal: pause.plan.goal, project: pause.plan.projectName)
        }
        if let finished = plaqueBridge?.recentFinish(at: now) {
            return .init(phase: .finished, sessionID: finished.sessionID, startedAt: finished.startedAt,
                         goal: finished.goal, project: finished.project, nextStep: finished.nextStep)
        }
        return .init(phase: .idle)
    }

    private func isFixedEndSession(_ session: SessionState) -> Bool {
        Self.isFixedEnd(session, recorded: preference(Key.fixedEndStart, default: 0))
    }

    /// What follows the running block: the sequence's next step when one is
    /// running, else the break this session earns by running its full length.
    static func plaqueNext(after session: SessionState, sequence: SequenceRun?, endsAt: Date?,
                           settingsBreak: TimeInterval, fixedEnd: Bool) -> PlaqueFocusSnapshot.Next? {
        if let sequence {
            switch sequence.next {
            case .rest(let length, _)?: return .init(kind: .break, startsAt: endsAt, minutes: Int((length / 60).rounded()))
            case .work(let plan)?: return .init(kind: .block, startsAt: endsAt, minutes: plan.duration.map { Int(($0 / 60).rounded()) })
            case nil: return .init(kind: .finish, startsAt: endsAt, minutes: nil)
            }
        }
        let length = session.plan.breakLength ?? settingsBreak
        guard session.plan.duration != nil, length > 0, !fixedEnd else { return nil }
        return .init(kind: .break, startsAt: endsAt, minutes: Int((length / 60).rounded()))
    }

    /// "Block 2 of 3": work blocks only. On a break, the block that comes next.
    static func plaqueSequence(_ run: SequenceRun?) -> PlaqueFocusSnapshot.Sequence? {
        guard let run, run.steps.indices.contains(run.index) else { return nil }
        let work = run.steps.filter(\.isWork).count
        guard work > 0 else { return nil }
        let throughCurrent = run.steps.prefix(run.index + 1).filter(\.isWork).count
        let step = run.current?.isWork == true ? throughCurrent : min(work, throughCurrent + 1)
        return .init(name: run.name, step: max(1, step), count: work)
    }
}
