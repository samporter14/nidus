//
//  FocusScheduler.swift
//  Nidus
//
//  Runs the weekly schedules: one Timer, set for the next moment that needs
//  anything (the heads-up a minute before a start, then the start), and set
//  again whenever that moment can have moved: the schedules were edited, the
//  Mac woke, the clock or time zone changed, the day turned over. Nothing
//  polls, and with no schedule on there is no timer at all.
//
//  The rules (when a run starts, what counts as missed) are pure functions
//  in Core/FocusSchedule.swift. This file only acts on them. It never runs
//  in a demo, a render or a test: the model starts it from activate() and
//  only outside Demo, and the tests call evaluate() on a fake host.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Settings

extension NidusModel.Key {
    static let schedules = "schedules"
    /// Schedule id to the start of the last run dealt with.
    static let scheduleHandled = "scheduleHandled"
    /// When the last session with a fixed end started.
    static let fixedEndStart = "fixedEndStart"
}

extension NidusModel {
    static let schedulePagePrefix = "schedule:"

    var schedules: [FocusSchedule] {
        get { preference(Key.schedules, default: [FocusSchedule]()) }
        set { setPreference(newValue, Key.schedules) }
    }

    /// The last run of each schedule that was started, skipped or passed
    /// over. Kept so a session ended early is not started again by a wake or
    /// a relaunch inside the same window.
    var scheduleHandled: [String: Date] {
        get { preference(Key.scheduleHandled, default: [String: Date]()) }
        set { setPreference(newValue, Key.scheduleHandled) }
    }

    /// A new schedule starts from what the popover has chosen. It is on at
    /// once; a run already under way when it is made is not started (see
    /// `FocusScheduler.Reason.edited`).
    func addSchedule() {
        let schedule = FocusSchedule(categoryIDs: selectedCategoryIDs, mode: mode)
        schedules.append(schedule)
        host?.workspace.openSettingsPage(Self.schedulePagePrefix + schedule.id, title: "New schedule")
    }

    func updateSchedule(_ id: String, _ change: (inout FocusSchedule) -> Void) {
        var all = schedules
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[index])
        guard all[index] != schedules[index] else { return }
        schedules = all
    }

    func deleteSchedule(_ id: String) {
        schedules.removeAll { $0.id == id }
        host?.workspace.goBackInSettings()
    }

    /// Notes that the session just started ends at a time set outside it, so
    /// the break that follows a full-length session is not taken.
    func noteFixedEnd(_ fixed: Bool) {
        guard fixed, let started = controller?.engine.session?.startedAt else { return }
        setPreference(started.timeIntervalSince1970, Key.fixedEndStart)
    }

    /// A session with a fixed end is over when it ends: a break would only
    /// start the same length again, a schedule's three hours at 12:05, or a
    /// meeting's session blocking Slack again during the meeting. Called as
    /// the session ends, before the wrap-up card reads whether a break is on.
    func endBreakAfterFixedEnd(_ final: SessionState) {
        let recorded: Double = preference(Key.fixedEndStart, default: 0)
        guard Self.isFixedEnd(final, recorded: recorded), controller?.engine.isOnBreak == true else { return }
        controller?.endBreak()
    }

    /// Whether this session is the one noted. Compared to the second: the
    /// session file may hold its start less exactly than the note does.
    static func isFixedEnd(_ final: SessionState, recorded: Double) -> Bool {
        recorded > 0 && abs(final.startedAt.timeIntervalSince1970 - recorded) < 1
    }

    /// "2 schedules on", for the link in Settings.
    var schedulesSummary: String {
        let on = schedules.filter(\.isOn).count
        switch (schedules.count, on) {
        case (0, _): return "Start a session on its own, on days and times you pick."
        case (_, 0): return "None on"
        default: return "\(on) on"
        }
    }

    /// The scheduler is started and stopped with the model, and not at all in
    /// a demo, render or capture: the sample sessions block nothing, and a
    /// schedule that fired there would start a real one.
    func startSchedules() {
        meetings.start(preferenceChanges: host?.preferences.didChange) { [weak self] in self?.objectWillChange.send() }
        guard !Demo.isActive, harnessScenario == nil, let host else { return }
        scheduler.start(host: self, preferenceChanges: host.preferences.didChange)
    }

    func stopSchedules() {
        scheduler.stop()
        meetings.stop()
        host?.hud.dismiss(id: Self.scheduleHUDID)
    }
}

// MARK: - The scheduler

/// What the scheduler asks of the app around it. The model is the real one;
/// the tests use a fake, so no session is ever started and no card shown.
@MainActor
protocol ScheduleHost: AnyObject {
    var schedules: [FocusSchedule] { get }
    var scheduleHandled: [String: Date] { get set }
    /// A session is running (or paused) or a break is on.
    var isSessionOrBreakOn: Bool { get }
    /// Starts the run's session, ending at its end. False if nothing started.
    func startScheduled(_ occurrence: FocusSchedule.Occurrence, minutes: Int,
                        asksBrowserAccess: Bool, missed: Bool) -> Bool
    func presentHeadsUp(for occurrence: FocusSchedule.Occurrence)
    func dismissHeadsUp()
    func logSchedule(_ message: String)
}

@MainActor
final class FocusScheduler {
    /// Why it is looking, which decides little: only an edit differs, because
    /// a schedule made or changed inside its window must not start a session
    /// by itself (see `evaluate`). Everything else may make up a start that
    /// was missed.
    enum Reason: Equatable {
        case launch, timer, wake, clockChange, edited
    }

    /// The start is taken a moment after its time, so a session that ends at
    /// exactly that time (back-to-back schedules) has finished first.
    static let settle: TimeInterval = 1.5
    /// After a wake or a clock change, long enough for the rest of the app to
    /// have dealt with it.
    static let wakeDelay: TimeInterval = 2
    /// A heads-up this close to the start is not worth showing.
    static let minimumHeadsUp: TimeInterval = 10

    private weak var host: ScheduleHost?
    var now: () -> Date
    var calendar: () -> Calendar
    /// The next time the timer is set for, if it is.
    private(set) var nextWake: Date?
    private var timer: Timer?
    private var pendingReason: Reason = .timer
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var cancellables: Set<AnyCancellable> = []
    /// Runs whose heads-up has been shown, so it shows once.
    private var announced: Set<String> = []
    /// The schedules as of the last look, to tell which an edit changed.
    private var known: [FocusSchedule] = []
    private var isLive = false

    init(host: ScheduleHost? = nil, now: @escaping () -> Date = { Date() },
         calendar: @escaping () -> Calendar = { .autoupdatingCurrent }) {
        self.host = host
        self.now = now
        self.calendar = calendar
    }

    // MARK: Live

    func start(host: ScheduleHost, preferenceChanges: PassthroughSubject<String, Never>) {
        // Never in a demo, render or capture, whatever called this.
        guard !isLive, !Demo.isActive else { return }
        isLive = true
        self.host = host
        let workspace = NSWorkspace.shared.notificationCenter
        listen(workspace, to: NSWorkspace.didWakeNotification, as: .wake)
        let center = NotificationCenter.default
        listen(center, to: .NSSystemClockDidChange, as: .clockChange)
        listen(center, to: .NSSystemTimeZoneDidChange, as: .clockChange)
        listen(center, to: .NSCalendarDayChanged, as: .timer)
        preferenceChanges
            .filter { $0 == NidusModel.Key.schedules }
            .sink { [weak self] _ in self?.run(.edited) }
            .store(in: &cancellables)
        run(.launch)
    }

    func stop() {
        isLive = false
        timer?.invalidate()
        timer = nil
        nextWake = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        cancellables.removeAll()
        announced = []
        known = []
        host = nil
    }

    private func listen(_ center: NotificationCenter, to name: Notification.Name, as reason: Reason) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookAgain(after: reason) }
        }
        observers.append((center, token))
    }

    /// Looks again in a moment, once the rest of the app has dealt with it.
    private func lookAgain(after reason: Reason) {
        pendingReason = reason
        arm(at: now().addingTimeInterval(reason == .timer ? 0 : Self.wakeDelay))
    }

    private func run(_ reason: Reason) {
        arm(at: evaluate(reason))
    }

    private func fired() {
        let reason = pendingReason
        pendingReason = .timer
        run(reason)
    }

    private func arm(at date: Date?) {
        timer?.invalidate()
        timer = nil
        nextWake = date
        guard isLive, let date else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fired() }
        }
        timer.tolerance = 0.2
        // Common modes, so it fires while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: The decision

    /// Deals with every run in progress, shows the heads-up if one is near,
    /// and returns when to look next. It is idempotent: the timer and a wake
    /// can both ask for the same moment, and the second changes nothing.
    ///
    /// After an edit, the runs of the schedules it made or moved (new, turned
    /// on, other days or times) are marked dealt with without starting: making
    /// a schedule at 10:00 must not start a session at 10:00. The schedules it
    /// left alone, a goal typed into another one, say, are looked at as ever.
    @discardableResult
    func evaluate(_ reason: Reason) -> Date? {
        guard let host else { return nil }
        let now = now()
        let calendar = calendar()
        let schedules = host.schedules
        var handled = host.scheduleHandled
        let changed = Set(schedules.filter { schedule in
            known.first { $0.id == schedule.id }.map(schedule.changesTiming(from:)) ?? true
        }.map(\.id))
        known = schedules

        for run in FocusSchedule.inProgress(at: now, schedules: schedules, calendar: calendar)
        where !FocusSchedule.isHandled(run, in: handled) {
            // Recorded for every run found, not only the one that starts: the
            // others are passed over, and must not start when the first ends.
            handled[run.schedule.id] = run.start
            if reason == .edited, changed.contains(run.schedule.id) { continue }
            begin(run, at: now, host: host)
        }
        let live = Set(schedules.map(\.id))
        handled = handled.filter { live.contains($0.key) }
        if handled != host.scheduleHandled { host.scheduleHandled = handled }

        guard let next = FocusSchedule.nextStart(after: now, schedules: schedules, calendar: calendar) else {
            return nil
        }
        let until = next.start.timeIntervalSince(now)
        if until > FocusSchedule.headsUpLead { return next.start.addingTimeInterval(-FocusSchedule.headsUpLead) }
        if until >= Self.minimumHeadsUp, !announced.contains(next.id),
           !FocusSchedule.isHandled(next, in: handled), !host.isSessionOrBreakOn {
            announced.insert(next.id)
            host.presentHeadsUp(for: next)
        }
        return next.start.addingTimeInterval(Self.settle)
    }

    private func begin(_ run: FocusSchedule.Occurrence, at now: Date, host: ScheduleHost) {
        host.dismissHeadsUp()
        guard !host.isSessionOrBreakOn else {
            return host.logSchedule("Scheduled start skipped: a session or break was already on")
        }
        switch FocusSchedule.decide(run, now: now) {
        case .skip(let reason):
            host.logSchedule("Scheduled start skipped: \(reason == .tooLate ? "too little of the window was left" : "nothing to do")")
        case .start(let minutes, let missed):
            if host.startScheduled(run, minutes: minutes, asksBrowserAccess: false, missed: missed) {
                host.logSchedule(missed ? "Scheduled session started late, for \(minutes) min" : "Scheduled session started, for \(minutes) min")
            } else {
                host.logSchedule("Scheduled start skipped: nothing to block")
            }
        }
    }

    // MARK: The card's buttons

    /// "Skip" on the heads-up: this run does not start.
    func skip(_ occurrence: FocusSchedule.Occurrence) {
        guard let host else { return }
        markHandled(occurrence, host: host)
        host.dismissHeadsUp()
        host.logSchedule("Scheduled start skipped by the user")
        run(.timer)
    }

    /// "Start now" on the heads-up: the session starts, and ends where the
    /// window does. It is a click, so it may ask a browser for access.
    func startNow(_ occurrence: FocusSchedule.Occurrence) {
        guard let host else { return }
        markHandled(occurrence, host: host)
        host.dismissHeadsUp()
        let now = now()
        guard !host.isSessionOrBreakOn else {
            return host.logSchedule("Scheduled start skipped: a session or break was already on")
        }
        guard let minutes = FocusSchedule.minutes(until: occurrence.end, from: now),
              host.startScheduled(occurrence, minutes: minutes, asksBrowserAccess: true, missed: false) else {
            return host.logSchedule("Scheduled start skipped: nothing to block")
        }
        host.logSchedule("Scheduled session started early, for \(minutes) min")
        run(.timer)
    }

    private func markHandled(_ occurrence: FocusSchedule.Occurrence, host: ScheduleHost) {
        var handled = host.scheduleHandled
        handled[occurrence.schedule.id] = max(handled[occurrence.schedule.id] ?? .distantPast, occurrence.start)
        host.scheduleHandled = handled
    }
}

// MARK: - The model as host

extension NidusModel: ScheduleHost {
    var isSessionOrBreakOn: Bool { isActive || isOnBreak }

    func startScheduled(_ occurrence: FocusSchedule.Occurrence, minutes: Int,
                        asksBrowserAccess: Bool, missed: Bool) -> Bool {
        guard startSession(occurrence.schedule.request(minutes: minutes, asksBrowserAccess: asksBrowserAccess)) else {
            return false
        }
        if missed { presentScheduleStartedHUD(for: occurrence) }
        return true
    }

    func logSchedule(_ message: String) {
        host?.log.notice("\(message, privacy: .public)")
    }
}

extension FocusSchedule {
    /// A scheduled session, as `startSession` takes it. The goal is the
    /// schedule's or none; a half-typed goal in the popover is never used.
    func request(minutes: Int, asksBrowserAccess: Bool = false) -> SessionRequest {
        SessionRequest(goal: goal, minutes: minutes, categoryIDs: categoryIDs, mode: mode, strict: strict,
                       asksBrowserAccess: asksBrowserAccess, hasFixedEnd: true)
    }
}

// MARK: - Cards

extension NidusModel {
    static let scheduleHUDID = "focus.schedule"

    /// What the run is about: its goal, or what it blocks.
    func scheduleDetail(_ schedule: FocusSchedule) -> String {
        let goal = schedule.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return goal.isEmpty ? schedule.categorySummary(categories: categories) : goal
    }

    /// A minute before a scheduled start: it begins by itself, unless skipped.
    func presentHeadsUp(for run: FocusSchedule.Occurrence) {
        guard let host else { return }
        let until = run.start.timeIntervalSinceNow
        let title = until > 50 ? "Focus starts in 1 min" : "Focus starts in under a minute"
        let detail = scheduleDetail(run.schedule)
        let request = DropletHUDRequest(
            id: Self.scheduleHUDID,
            // Until the start, and a little over, so the buttons last the minute.
            duration: min(70, max(5, until + 1)),
            priority: .normal,
            accessibilityLabel: "\(title). \(detail). Skip or start now.",
            isExpanded: true,
            expandedContentHeight: 64
        ) {
            FocusHUDStrip(symbol: "calendar.badge.clock", text: "Focus")
        } expanded: { [weak self] in
            FocusScheduleHeadsUpCard(title: title, detail: detail,
                                     skip: { self?.scheduler.skip(run) },
                                     startNow: { self?.scheduler.startNow(run) })
        }
        if host.hud.present(request) {
            host.feedback.play(.tick)
        }
    }

    /// A session that started because the Mac woke, or Nidus opened, inside a
    /// window: the only start nobody was told about a minute ahead.
    func presentScheduleStartedHUD(for run: FocusSchedule.Occurrence) {
        guard let host else { return }
        let until = run.end.formatted(date: .omitted, time: .shortened)
        let detail = "Until \(until) · \(scheduleDetail(run.schedule))"
        let request = DropletHUDRequest(
            id: Self.scheduleHUDID,
            duration: 8,
            priority: .normal,
            accessibilityLabel: "Focus started, from your schedule. Until \(until).",
            isExpanded: true,
            expandedContentHeight: 64
        ) {
            FocusHUDStrip(symbol: "calendar.badge.clock", text: "Focus")
        } expanded: {
            FocusNoticeCard(symbol: "calendar.badge.clock", variants: [
                .init(title: Text(verbatim: "Focus started"), detail: Text(verbatim: detail), button: "OK"),
                .init(title: Text(verbatim: "Focus started"), detail: Text(verbatim: "Until \(until)"), button: "OK", showsSymbol: false),
            ]) {
                host.hud.dismiss(id: Self.scheduleHUDID)
            }
        }
        host.hud.present(request)
    }

    func dismissHeadsUp() { host?.hud.dismiss(id: Self.scheduleHUDID) }
}

/// The heads-up: what is about to start, with Skip and Start now. On a
/// narrower card it drops the mark.
struct FocusScheduleHeadsUpCard: View {
    let title: String
    let detail: String
    let skip: () -> Void
    let startNow: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showsSymbol: true, last: false)
            row(showsSymbol: false, last: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func row(showsSymbol: Bool, last: Bool) -> some View {
        HStack(alignment: .center, spacing: DroppySpacing.md) {
            if showsSymbol {
                SettingsTile(symbol: "calendar.badge.clock", size: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Text(verbatim: detail)
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: !last, vertical: false)
            Spacer(minLength: DroppySpacing.sm)
            Button("Skip", action: skip)
                .buttonStyle(.bordered)
                .fixedSize()
                .accessibilityLabel("Skip this scheduled session")
            Button("Start now", action: startNow)
                .buttonStyle(.borderedProminent)
                .tint(FocusPalette.clay)
                .fixedSize()
                .accessibilityLabel("Start the session now")
        }
    }
}
