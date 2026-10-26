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
//  A schedule that checks the calendar (0.4) gets one more look at the
//  heads-up, and a card that can shorten or delay the block. What was chosen
//  is held here, in memory, as `adjustments`; the run it changes then goes
//  through the same begin() as every other, so the session and break guard
//  and the missed-start rules are the ones all runs have.
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
    nonisolated static let schedulePagePrefix = "schedule:"

    var schedules: [FocusSchedule] {
        get { preferenceList(Key.schedules) }
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

    /// The scheduler is started and stopped with the model, and not at all in
    /// a demo, render or capture: the sample sessions block nothing, and a
    /// schedule that fired there would start a real one.
    func startSchedules() {
        meetings.start(preferenceChanges: host?.preferences.didChange) { [weak self] in self?.objectWillChange.send() }
        guard !Demo.isActive, harnessScenario == nil, let host else { return }
        scheduler.calendarSource = { [weak self] in self?.meetings.source }
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
    /// The screen is locked. A shortened or delayed run waits for it.
    var isScreenLocked: Bool { get }
    /// Starts the run's session, ending at its end. False if nothing started.
    func startScheduled(_ occurrence: FocusSchedule.Occurrence, minutes: Int,
                        asksBrowserAccess: Bool, missed: Bool) -> Bool
    func presentHeadsUp(for occurrence: FocusSchedule.Occurrence)
    /// The same card, with the meeting that is in the way when there is one.
    func presentHeadsUp(for occurrence: FocusSchedule.Occurrence, conflict: ScheduleConflict?)
    func dismissHeadsUp()
    func logSchedule(_ message: String)
}

extension ScheduleHost {
    /// A host with no calendar to show gives the plain card.
    func presentHeadsUp(for occurrence: FocusSchedule.Occurrence, conflict: ScheduleConflict?) {
        presentHeadsUp(for: occurrence)
    }
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
    /// Where the calendar is read, asked for at each check and never kept. nil
    /// (the default) is a Mac with nothing to read, which is "unknown".
    var calendarSource: () -> CalendarSource? = { nil }

    /// A run the person shortened or delayed from the heads-up, one per
    /// schedule, held here and nowhere else. A relaunch drops it (the original
    /// run is already marked as dealt with, so nothing starts in its place).
    struct Adjustment: Equatable {
        /// The scheduled window it was made from, so a change of clock, zone
        /// or schedule since is seen and the adjustment dropped.
        let original: FocusSchedule.Occurrence
        /// What runs instead.
        let run: FocusSchedule.Occurrence
        /// It ends where a meeting begins, and so gets no slack on its end.
        var endsAtMeeting: Bool { run.end != original.end }
    }
    private(set) var adjustments: [String: Adjustment] = [:]

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
        // A shortened or delayed run held back by the lock screen is looked
        // at again once someone is there.
        listen(DistributedNotificationCenter.default(), to: FocusController.screenUnlockedNotification, as: .wake)
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
        adjustments = [:]
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
        // Before the record is read: an adjusted run that was missed marks its
        // scheduled run as dealt with.
        dropStaleAdjustments(at: now, schedules: schedules, calendar: calendar, host: host)
        var handled = host.scheduleHandled
        let changed = Set(schedules.filter { schedule in
            known.first { $0.id == schedule.id }.map(schedule.changesTiming(from:)) ?? true
        }.map(\.id))
        known = schedules

        var runs = FocusSchedule.inProgress(at: now, schedules: schedules, calendar: calendar)
        let endsAtMeeting = substituteAdjustments(into: &runs, at: now, schedules: schedules)
        // A run the person shortened or delayed starts only with them there:
        // behind the lock screen it waits, and on unlock the usual late-start
        // rule decides (it starts if at least five minutes of it are left).
        var waiting: Set<String> = []
        for run in runs where !FocusSchedule.isHandled(run, in: handled) {
            if host.isScreenLocked, adjustments[run.schedule.id]?.run.start == run.start {
                waiting.insert(run.schedule.id)
                host.logSchedule("Adjusted start waiting: the screen is locked")
                continue
            }
            // Recorded for every run found, not only the one that starts: the
            // others are passed over, and must not start when the first ends.
            handled[run.schedule.id] = run.start
            if reason == .edited, changed.contains(run.schedule.id) { continue }
            begin(run, at: now, host: host, slack: endsAtMeeting.contains(run.id) ? 0 : 10)
        }
        // An adjusted run that came up was used or passed over, once.
        for run in runs where adjustments[run.schedule.id]?.run.start == run.start && !waiting.contains(run.schedule.id) {
            adjustments[run.schedule.id] = nil
        }
        let live = Set(schedules.map(\.id))
        handled = handled.filter { live.contains($0.key) }
        if handled != host.scheduleHandled { host.scheduleHandled = handled }

        guard let next = nextRun(after: now, schedules: schedules, calendar: calendar) else { return nil }
        let until = next.start.timeIntervalSince(now)
        if until > FocusSchedule.headsUpLead { return next.start.addingTimeInterval(-FocusSchedule.headsUpLead) }
        if until >= Self.minimumHeadsUp, !announced.contains(next.id),
           !FocusSchedule.isHandled(next, in: handled), !host.isSessionOrBreakOn {
            announced.insert(next.id)
            announce(next, at: now, host: host)
        }
        return next.start.addingTimeInterval(Self.settle)
    }

    private func begin(_ run: FocusSchedule.Occurrence, at now: Date, host: ScheduleHost, slack: TimeInterval = 10) {
        host.dismissHeadsUp()
        guard !host.isSessionOrBreakOn else {
            return host.logSchedule("Scheduled start skipped: a session or break was already on")
        }
        switch FocusSchedule.decide(run, now: now, slack: slack) {
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

    // MARK: Shortened and delayed runs

    /// Drops the adjustments that no longer fit: the schedule is gone, off or
    /// moved, the clock or zone changed so its window is somewhere else, or the
    /// time has passed. The window is worked out again in today's calendar, so
    /// the comparison is with the zone the Mac is in now.
    private func dropStaleAdjustments(at now: Date, schedules: [FocusSchedule], calendar: Calendar, host: ScheduleHost) {
        for (id, adjustment) in adjustments {
            let window = schedules.first { $0.id == id }?.occurrence(onDayOf: adjustment.original.start, calendar: calendar)
            let why: String?
            if window == nil {
                why = "its schedule was changed or turned off"
            } else if window?.start != adjustment.original.start || window?.end != adjustment.original.end {
                why = "the clock or time zone changed"
            } else if now >= adjustment.run.end {
                // The person chose this run and it was missed (the Mac slept
                // through it). The scheduled run does not take its place: it
                // would run straight through the meeting that was avoided.
                markHandled(adjustment.original, host: host)
                why = "its time passed"
            } else {
                why = nil
            }
            guard let why else { continue }
            adjustments[id] = nil
            host.logSchedule("Adjusted start dropped: \(why)")
        }
    }

    /// Puts each adjusted run that is under way where the scheduled one would
    /// be (a shortened run replaces the run it shortens; a delayed one joins
    /// the list, the run it delays having been marked as dealt with). Returns
    /// the ids of those that end at a meeting.
    private func substituteAdjustments(into runs: inout [FocusSchedule.Occurrence], at now: Date,
                                       schedules: [FocusSchedule]) -> Set<String> {
        var endsAtMeeting: Set<String> = []
        for schedule in schedules {
            guard let adjustment = adjustments[schedule.id] else { continue }
            let run = FocusSchedule.Occurrence(schedule: schedule, start: adjustment.run.start, end: adjustment.run.end)
            guard run.start <= now, now < run.end else { continue }
            runs.removeAll { $0.schedule.id == schedule.id && $0.start == run.start }
            runs.append(run)
            if adjustment.endsAtMeeting { endsAtMeeting.insert(run.id) }
        }
        runs = runs.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        return endsAtMeeting
    }

    /// The next start of anything: the schedules' own, or a delayed run.
    private func nextRun(after now: Date, schedules: [FocusSchedule], calendar: Calendar) -> FocusSchedule.Occurrence? {
        let delayed = schedules.compactMap { schedule in
            adjustments[schedule.id].map {
                FocusSchedule.Occurrence(schedule: schedule, start: $0.run.start, end: $0.run.end)
            }
        }.filter { $0.start > now }
        let candidates = [FocusSchedule.nextStart(after: now, schedules: schedules, calendar: calendar)].compactMap { $0 } + delayed
        // The first of equals wins, so the scheduled run is not replaced by
        // its own shortened copy.
        return candidates.min { $0.start < $1.start }
    }

    // MARK: The calendar

    private enum Check {
        /// The calendar couldn't be read: access not given, refused, or gone.
        case unknown
        case clear
        case conflict(ScheduleConflict)
    }

    /// Reads the calendar now and works out whether the run meets a meeting.
    /// Access is checked on every read; an unreadable calendar is unknown,
    /// never empty. Nothing but start and end times is read.
    private func check(_ run: FocusSchedule.Occurrence, at now: Date) -> Check {
        let gap = TimeInterval(run.schedule.calendarBuffer * 60)
        let from = max(run.start, now)
        guard let spans = calendarSource()?.busySpans(from: from.addingTimeInterval(-gap), to: run.end.addingTimeInterval(gap)) else {
            return .unknown
        }
        return FocusSchedule.conflict(for: run, spans: spans, now: now).map(Check.conflict) ?? .clear
    }

    /// The heads-up: the plain card, or with the meeting in the way when the
    /// schedule asks for the calendar to be checked and it can be.
    private func announce(_ run: FocusSchedule.Occurrence, at now: Date, host: ScheduleHost) {
        guard run.schedule.checksCalendar else { return host.presentHeadsUp(for: run, conflict: nil) }
        switch check(run, at: now) {
        case .unknown:
            host.logSchedule("The calendar couldn't be checked; the schedule runs as set")
            host.presentHeadsUp(for: run, conflict: nil)
        case .clear:
            host.presentHeadsUp(for: run, conflict: nil)
        case .conflict(let conflict):
            host.presentHeadsUp(for: run, conflict: conflict)
        }
    }

    enum Adjust { case shorten, delay }

    /// "Shorten" or "Delay" on the heads-up. A card drawn a moment ago may be
    /// out of date, so nothing it said is trusted: the window is worked out
    /// again in today's calendar, the calendar is read again, and the choice
    /// is made from what it says now. If the meeting has moved, the new time
    /// is used; if it has gone, or the option would now leave under ten
    /// minutes, nothing is changed and the run starts as scheduled (with the
    /// card, in the second case, showing what is left to choose).
    func adjust(_ choice: Adjust, _ shown: FocusSchedule.Occurrence) {
        guard let host else { return }
        let now = now()
        let calendar = calendar()
        let id = shown.schedule.id
        // A delayed run's window comes from the run it delays.
        let base = adjustments[id].flatMap { $0.run.start == shown.start ? $0.original : nil } ?? shown
        guard let schedule = host.schedules.first(where: { $0.id == id }), schedule.isOn, schedule.checksCalendar,
              let window = schedule.occurrence(onDayOf: base.start, calendar: calendar),
              window.start == base.start, window.end == base.end else {
            host.dismissHeadsUp()
            host.logSchedule("Calendar suggestion dropped: the schedule or the clock changed")
            return run(.timer)
        }
        guard !FocusSchedule.isHandled(shown, in: host.scheduleHandled), !host.isSessionOrBreakOn else {
            host.dismissHeadsUp()
            return host.logSchedule("Calendar suggestion dropped: the run was dealt with, or a session or break was on")
        }
        let current = FocusSchedule.Occurrence(schedule: schedule, start: shown.start, end: shown.end)
        switch check(current, at: now) {
        case .unknown:
            host.dismissHeadsUp()
            host.logSchedule("The calendar couldn't be checked; the schedule runs as set")
        case .clear:
            host.dismissHeadsUp()
            host.logSchedule("The meeting is no longer in the way; the schedule runs as set")
        case .conflict(let conflict):
            let target = choice == .shorten ? conflict.shortenEnd : conflict.delayStart
            guard let target else {
                host.logSchedule("The calendar changed: that choice would leave under 10 minutes")
                return host.presentHeadsUp(for: current, conflict: conflict)
            }
            let time = ScheduleConflict.clock(target, calendar: calendar)
            switch choice {
            case .shorten:
                adjustments[id] = Adjustment(original: base, run: FocusSchedule.Occurrence(schedule: schedule, start: current.start, end: target))
                host.logSchedule("Scheduled session will end at \(time), before a meeting")
            case .delay:
                // The run it delays is dealt with; the delayed one is its own.
                markHandled(current, host: host)
                adjustments[id] = Adjustment(original: base, run: FocusSchedule.Occurrence(schedule: schedule, start: target, end: current.end))
                host.logSchedule("Scheduled session delayed to \(time), after a meeting")
            }
            host.dismissHeadsUp()
        }
        self.run(.timer)
    }

    func shorten(_ occurrence: FocusSchedule.Occurrence) { adjust(.shorten, occurrence) }
    func delay(_ occurrence: FocusSchedule.Occurrence) { adjust(.delay, occurrence) }

    private func forgetAdjustment(for occurrence: FocusSchedule.Occurrence) {
        if adjustments[occurrence.schedule.id]?.run.start == occurrence.start {
            adjustments[occurrence.schedule.id] = nil
        }
    }

    // MARK: The card's buttons

    /// "Skip" on the heads-up: this run does not start.
    func skip(_ occurrence: FocusSchedule.Occurrence) {
        guard let host else { return }
        markHandled(occurrence, host: host)
        forgetAdjustment(for: occurrence)
        host.dismissHeadsUp()
        host.logSchedule("Scheduled start skipped by the user")
        run(.timer)
    }

    /// "Start now" on the heads-up: the session starts, and ends where the
    /// window does. It is a click, so it may ask a browser for access.
    func startNow(_ occurrence: FocusSchedule.Occurrence) {
        guard let host else { return }
        markHandled(occurrence, host: host)
        forgetAdjustment(for: occurrence)
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
    var isScreenLocked: Bool { controller?.screenIsLocked ?? false }

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
        presentHeadsUp(for: run, conflict: nil)
    }

    /// The same card with a meeting in the way: it says when, never which,
    /// and offers Shorten, Delay and Skip. Left alone it does nothing, and the
    /// session begins as scheduled.
    func presentHeadsUp(for run: FocusSchedule.Occurrence, conflict: ScheduleConflict?) {
        guard let host else { return }
        let until = run.start.timeIntervalSinceNow
        let title = until > 50 ? "Focus starts in 1 min" : "Focus starts in under a minute"
        let calendar = scheduler.calendar()
        let detail = conflict?.line(calendar: calendar) ?? scheduleDetail(run.schedule)
        let choices = conflict.map { found in
            FocusScheduleHeadsUpCard.Choices(
                shortenTime: found.shortenEnd.map { ScheduleConflict.clock($0, calendar: calendar) },
                delayTime: found.delayStart.map { ScheduleConflict.clock($0, calendar: calendar) })
        }
        let spoken = conflict == nil ? "Skip or start now." : "Shorten, delay or skip."
        let request = HUDRequest(
            id: Self.scheduleHUDID,
            // Until the start, and a little over, so the buttons last the minute.
            duration: min(70, max(5, until + 1)),
            accessibilityLabel: "\(title). \(detail). \(spoken)"
        ) { [weak self] in
            FocusScheduleHeadsUpCard(title: title, detail: detail, choices: choices,
                                     skip: { self?.scheduler.skip(run) },
                                     startNow: { self?.scheduler.startNow(run) },
                                     shorten: { self?.scheduler.shorten(run) },
                                     delay: { self?.scheduler.delay(run) })
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
        let request = HUDRequest(
            id: Self.scheduleHUDID,
            duration: 8,
            accessibilityLabel: "Focus started, from your schedule. Until \(until)."
        ) {
            FocusNoticeCard(symbol: NidusSymbols.calendar, variants: [
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

/// The heads-up: what is about to start, with Skip and Start now. With a
/// meeting in the way it says when, and offers Shorten and Delay (whichever
/// would leave ten minutes or more) and Skip instead; Start now is the start
/// that is coming anyway. On a narrower card it drops the mark.
struct FocusScheduleHeadsUpCard: View {
    /// What a meeting in the way allows, as the times each button leads to.
    /// An option that is nil is not shown.
    struct Choices: Equatable {
        var shortenTime: String?
        var delayTime: String?
    }

    let title: String
    let detail: String
    var choices: Choices?
    let skip: () -> Void
    let startNow: () -> Void
    var shorten: () -> Void = {}
    var delay: () -> Void = {}

    var body: some View {
        if let choices {
            conflictBody(choices)
                // Without a floor a window around it may shrink until the
                // line wraps letter by letter, and call that its least height.
                .frame(minWidth: 340, maxWidth: .infinity, alignment: .leading)
        } else {
            ViewThatFits(in: .horizontal) {
                row(showsSymbol: true, last: false)
                row(showsSymbol: false, last: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func texts(lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AdaptiveColors.surfacePrimaryText)
            Text(verbatim: detail)
                .font(.system(size: 12))
                .foregroundStyle(AdaptiveColors.surfaceSecondaryText)
                .lineLimit(lines)
        }
    }

    private func row(showsSymbol: Bool, last: Bool) -> some View {
        HStack(alignment: .center, spacing: NidusSpacing.md) {
            if showsSymbol {
                SettingsTile(symbol: NidusSymbols.calendar, size: 28)
            }
            texts(lines: 1)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: !last, vertical: false)
            Spacer(minLength: NidusSpacing.sm)
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

    /// The meeting's line above, the buttons under it: the line is too long to
    /// share a row with three of them.
    private func conflictBody(_ choices: Choices) -> some View {
        VStack(alignment: .leading, spacing: NidusSpacing.sm) {
            HStack(alignment: .center, spacing: NidusSpacing.md) {
                SettingsTile(symbol: NidusSymbols.calendar, size: 28)
                texts(lines: 2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                buttons(choices, withTimes: true)
                buttons(choices, withTimes: false)
            }
        }
    }

    private func buttons(_ choices: Choices, withTimes: Bool) -> some View {
        HStack(spacing: NidusSpacing.sm) {
            Spacer(minLength: 0)
            Button("Skip", action: skip)
                .buttonStyle(.bordered)
                .fixedSize()
                .accessibilityLabel("Skip this scheduled session")
            if let time = choices.delayTime {
                Button(withTimes ? "Delay to \(time)" : "Delay", action: delay)
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .help("Start at \(time) instead, and end when the block was going to")
                    .accessibilityLabel("Delay the session to \(time)")
            }
            if let time = choices.shortenTime {
                Button(withTimes ? "Shorten to \(time)" : "Shorten", action: shorten)
                    .buttonStyle(.borderedProminent)
                    .tint(FocusPalette.clay)
                    .fixedSize()
                    .help("Start on time and end at \(time), before the meeting")
                    .accessibilityLabel("Shorten the session to end at \(time)")
            }
        }
    }
}
