//
//  FocusController.swift
//  Nidus
//
//  Runs a session: drives the engine once a second, keeps the app blocker's
//  rules in step with it, sweeps the browsers off the main thread, pauses for
//  sleep, and undoes everything when the session pauses or ends. Between
//  sessions the clock is stopped and nothing runs at all.
//
//  Everything start() sets up, stop() tears down. The app wraps this.
//

import AppKit
import ApplicationServices
import Combine

/// Something the session just stopped, for the "blocked" HUD.
enum BlockedItem: Equatable, Sendable {
    /// `quit` is false when the app was hidden instead.
    case app(bundleID: String, name: String, quit: Bool)
    case website(domain: String)

    /// What a snooze of this item lets through.
    var snoozeKey: String {
        switch self {
        case .app(let bundleID, _, _): return bundleID
        case .website(let domain): return domain
        }
    }

    var displayName: String {
        switch self {
        case .app(_, let name, _): return name
        case .website(let domain): return domain
        }
    }
}

@MainActor
final class FocusController: ObservableObject {
    let engine: SessionEngine

    /// Ticks once a second while there is a session; views that show a
    /// countdown read it. Between sessions it stands still.
    @Published private(set) var now = Date()
    /// Browsers Nidus may not script, so Settings can say so.
    @Published private(set) var browserAccess: [String: AppleEventError] = [:]

    /// Blocked apps that were asked to quit and are still running (bundle ID to
    /// name), found by the periodic sweep. Empty when nothing is enforcing.
    /// Updated only when it changes.
    @Published private(set) var refusedApps: [String: String] = [:]

    var appAction: AppBlocker.Action {
        get { appBlocker.action }
        set { appBlocker.action = newValue }
    }
    var snoozeLength: TimeInterval = SessionEngine.defaultSnooze
    /// Demos, renders and tests: whatever the engine says to block, nothing is
    /// quit and no browser is asked. A sample break with rules can be drawn
    /// without touching the Mac it is drawn on.
    var blocksNothing = false

    var onBlocked: (BlockedItem) -> Void = { _ in }
    var onSessionEvent: (SessionEvent) -> Void = { _ in }
    /// A snooze is about to run out: the item, and when.
    var onSnoozeEnding: (String, Date) -> Void = { _, _ in }
    /// A break is about to end and the next session start: when, and what.
    var onBreakEnding: (Date, SessionPlan) -> Void = { _, _ in }
    /// A session just opened its documents, folders and pages: how that came
    /// out, and the plan that asked. Only for a start that opened something.
    var onWorkspaceOpened: (WorkspaceReport, SessionPlan) -> Void = { _, _ in }

    /// How apps, files, pages and Shortcuts are opened. Tests and demos hand
    /// in one that records or does nothing.
    var opener: any WorkspaceOpening = SystemWorkspaceOpener()
    /// How a document or folder is found again.
    var launcher = WorkspaceLauncher()
    /// Which app opens a document, to say beforehand when a session blocks it.
    var appFinder: any DefaultAppFinding = SystemAppFinder()

    /// The break after a completed, timed session; 0 for none.
    var breakLength: TimeInterval {
        get { engine.breakLength }
        set { engine.breakLength = newValue }
    }
    static let breakWarningLead: TimeInterval = 15

    /// Finished sessions, for the stats. Recorded only while this is on.
    let history: FocusHistory
    var recordsHistory = true {
        didSet {
            guard oldValue != recordsHistory else { return }
            if !recordsHistory { invalidateActivityProbe(); engine.clearCurrentActivity() }
        }
    }
    /// Activity is opt-in and stays off in demos and when history is off.
    var activityTrackingEnabled = false {
        didSet {
            guard oldValue != activityTrackingEnabled else { return }
            invalidateActivityProbe()
            if !activityTrackingEnabled { engine.clearCurrentActivity() }
        }
    }
    var activityDocumentTitlesEnabled = false {
        didSet {
            guard oldValue != activityDocumentTitlesEnabled else { return }
            invalidateActivityProbe()
            if !activityDocumentTitlesEnabled { engine.removeCurrentActivityTitles() }
        }
    }
    var activityExcludedApps: Set<String> = [] {
        didSet {
            guard oldValue != activityExcludedApps else { return }
            invalidateActivityProbe()
            engine.excludeCurrentActivity(appIDs: activityExcludedApps)
        }
    }
    /// Tells the stats page something was added.
    @Published private(set) var historyVersion = 0

    private let blockPage: BlockPage
    private let browsers: BrowserBlocker
    /// Written when quitting put a session's tabs back. The session resumes
    /// on the next start(), and its first sweep blocks those tabs again:
    /// that is the same block as before, so it is not counted or shown.
    private let tabsRestoredMarker: URL
    /// The next sweep's redirects are tabs put back at quit; see above.
    private(set) var quietsNextSweep = false
    private let browserQueue = DispatchQueue(label: "focus.browsers", qos: .utility)
    private let activityQueue = DispatchQueue(label: "focus.activity", qos: .utility)
    private var activityProbeInFlight = false
    private var activityProbeGeneration = 0
    private var activityProbeAt: Date?
    private var activityDetail: ActivityDetail?
    private var activityDetailApp: (id: String, pid: pid_t)?
    private var activityDetailAt: Date?
    private var lastAppActivation: Date?
    private var sweepInFlight = false
    private lazy var appBlocker = AppBlocker(mode: .block([]), action: .terminate) { [weak self] app in
        self?.appWasBlocked(app)
    }
    private var timer: Timer?
    private var isStarted = false
    private var observers: [NSObjectProtocol] = []
    private var enforcing: Enforcement?
    /// When each item was last reported, so a relaunch loop is one HUD, not ten.
    private var lastReported: [String: Date] = [:]
    /// When the frontmost app was last credited, and ticks since a save.
    private var ticksSinceCheckpoint = 0
    /// Ticks spent enforcing since the app sweep last ran.
    private var enforcingTicks = 0
    /// Snoozes already warned about, by the end they were warned for, so a
    /// snooze taken again is warned about again.
    private var warnedSnoozes: [String: Date] = [:]
    private var warnedBreakEnd: Date?
    private var lockObservers: [NSObjectProtocol] = []
    private var clockObservers: [NSObjectProtocol] = []
    private var isScreenLocked = false
    /// The screen is locked: someone may not be there.
    var screenIsLocked: Bool { isScreenLocked }
    /// What macOS broadcasts as the screen locks and unlocks.
    static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
    /// Shortcuts run strictly in order, so an end followed at once by a start
    /// cannot leave a Focus mode off.
    private var shortcutChain: Task<Void, Never>?

    /// `now` is the engine's clock; tests move it by hand, and then trust it
    /// for the countdown. Left out, the countdown runs on the system's
    /// monotonic clock, which setting the date cannot move.
    init(directory: URL, now: (() -> Date)? = nil) {
        blockPage = BlockPage(directory: directory)
        browsers = BrowserBlocker(blockPage: blockPage)
        let store = FileSessionStore(url: directory.appendingPathComponent("session.json"))
        if let now {
            engine = SessionEngine(store: store, now: now)
        } else {
            engine = SessionEngine(store: store, monotonic: { SessionEngine.systemMonotonic() })
        }
        tabsRestoredMarker = directory.appendingPathComponent("tabs-restored")
        history = FocusHistory(url: directory.appendingPathComponent("history.json"))
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        try? blockPage.install()
        engine.onEvent = { [weak self] event in self?.handle(event) }
        engine.isAway = { [weak self] in self?.isScreenLocked ?? false }
        now = Date()
        engine.restore(allowActivity: recordsHistory && activityTrackingEnabled,
                       allowTitles: activityDocumentTitlesEnabled,
                       excludedApps: activityExcludedApps)
        if FileManager.default.fileExists(atPath: tabsRestoredMarker.path) {
            try? FileManager.default.removeItem(at: tabsRestoredMarker)
            quietsNextSweep = engine.session != nil || engine.isOnBreak
        }

        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemWillSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemDidWake() }
            },
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.lastAppActivation = Date()
                    self?.invalidateActivityProbe()
                }
            },
        ]
        let distributed = DistributedNotificationCenter.default()
        lockObservers = [
            distributed.addObserver(forName: Self.screenLockedNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenDidLock() }
            },
            distributed.addObserver(forName: Self.screenUnlockedNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenDidUnlock() }
            },
        ]
        clockObservers = [
            NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine.systemClockDidChange() }
            },
        ]
        applyEnforcement()
        updateClock()
    }

    /// Stops watching. The session itself is saved and resumes on the next
    /// start(), so this does not end it. With `restoringTabs` (Nidus is
    /// quitting), tabs on the block page go back to their pages first: a
    /// blocker that isn't running shouldn't leave them stuck. The next
    /// start() blocks them again, quietly.
    func stop(restoringTabs: Bool = false) {
        if restoringTabs, let enforcing, !(enforcing.mode == .block && enforcing.websites.isEmpty) {
            // After any sweep in flight, but bounded: each Apple Event has its
            // own timeout, so several hung browsers could hold the quit for
            // a long time. Past `quitRestoreTimeout` quitting goes on; a late
            // finish only touches `browsers` and the box, never this object.
            let browsers = self.browsers
            let box = RestoreCount()
            let done = DispatchSemaphore(value: 0)
            browserQueue.async {
                box.add(BrowserProfile.known.reduce(0) { count, browser in
                    count + ((try? browsers.restore(browser))?.count ?? 0)
                })
                done.signal()
            }
            let timedOut = done.wait(timeout: .now() + Self.quitRestoreTimeout) == .timedOut
            if Self.marksTabsRestored(restored: box.value, timedOut: timedOut,
                                      hasSession: engine.session != nil, isOnBreak: engine.isOnBreak) {
                FileManager.default.createFile(atPath: tabsRestoredMarker.path, contents: Data())
            }
        }
        isStarted = false
        invalidateActivityProbe()
        updateClock()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        lockObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        lockObservers.removeAll()
        clockObservers.forEach(NotificationCenter.default.removeObserver)
        clockObservers.removeAll()
        appBlocker.stop()
        enforcingTicks = 0
        if !refusedApps.isEmpty { refusedApps = [:] }
        enforcing = nil
        engine.checkpoint()
        engine.onEvent = { _ in }
    }

    func endSnooze(_ item: String) { engine.endSnooze(item) }

    // MARK: Away

    // A Mac that is asleep or locked is not focusing: the countdown stops
    // until both are over, the way it does for sleep. A Mac that wakes to
    // its lock screen is still away until it is unlocked. A pause the user
    // chose is left alone: these only end the pauses they began.

    func systemWillSleep() { engine.systemWillSleep() }

    func systemDidWake() {
        guard !isScreenLocked else { return }
        engine.systemDidWake()
    }

    func screenDidLock() {
        isScreenLocked = true
        engine.systemWillSleep()
    }

    func screenDidUnlock() {
        isScreenLocked = false
        engine.systemDidWake()
    }
    func skipBreak() {
        now = Date()
        engine.skipBreak()
    }
    func endBreak() { engine.endBreak() }

    private func warnAboutEndingBreak() {
        guard let end = engine.breakEnding(within: Self.breakWarningLead), warnedBreakEnd != end,
              let plan = engine.breakState?.plan else { return }
        warnedBreakEnd = end
        onBreakEnding(end, plan)
    }

    /// How long before a snooze ends it is announced: 30 seconds, or a third
    /// of a short snooze.
    var snoozeWarningLead: TimeInterval { min(30, max(10, snoozeLength / 3)) }

    private func warnAboutEndingSnoozes() {
        guard engine.isRunning else { return }
        for (item, end) in engine.snoozesEnding(within: snoozeWarningLead) where warnedSnoozes[item] != end {
            warnedSnoozes[item] = end
            onSnoozeEnding(item, end)
        }
    }

    /// The answer to "did you finish?" for a recorded session.
    func markFinished(_ id: SessionEntry.ID, _ finished: Bool) {
        guard history.setFinished(id, finished) else { return }
        historyVersion += 1
    }

    /// Names out of history and out of the running session; times stay.
    func removeActivityTitles() {
        history.removeActivityTitles()
        engine.removeCurrentActivityTitles()
        invalidateActivityProbe()
        historyVersion += 1
    }

    func clearHistory() {
        history.clear()
        invalidateActivityProbe()
        engine.clearCurrentActivity()
        historyVersion += 1
    }

    /// Called only from an explicit Settings action; never from a timer.
    @discardableResult
    func requestActivityAccessibilityAccess() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: Commands

    func start(_ plan: SessionPlan) {
        // The clock stood still between sessions. Bring it up to date before
        // the session exists, so the first countdown is right and nothing
        // animates twice.
        now = Date()
        engine.start(plan)
    }
    /// Starts a resolved sequence's first block. Called only by the model's
    /// guarded start path; the engine itself refuses while anything is on.
    @discardableResult
    func startSequence(_ run: SequenceRun) -> Bool {
        now = Date()
        return engine.startSequence(run)
    }
    func pause() { engine.pause() }
    func resume() { engine.resume() }
    func end() { engine.end() }
    /// Takes back the last early end, if the engine still allows it (see
    /// `SessionEngine.canUndoEnd`). The handler for `.undone` does the rest.
    @discardableResult
    func undoEnd() -> Bool {
        now = Date()
        return engine.undoEnd()
    }
    func extend(by seconds: TimeInterval) { engine.extend(by: seconds) }

    func snooze(_ item: String) {
        engine.snooze(item, for: snoozeLength)
    }

    // MARK: Private

    private func tick() {
        let previous = now
        now = Date()
        creditForeground(since: previous)
        engine.tick()
        warnAboutEndingSnoozes()
        warnAboutEndingBreak()
        if enforcing != nil { sweepBrowsers() }
        sweepApps()
        ticksSinceCheckpoint += 1
        if ticksSinceCheckpoint >= 15, engine.session != nil {
            ticksSinceCheckpoint = 0
            engine.checkpoint()
        }
    }

    /// Every few ticks, while enforcing, has the blocker take another look at
    /// apps that refused to quit, and republishes the refusals if they changed.
    private func sweepApps() {
        guard enforcing != nil else {
            enforcingTicks = 0
            if !refusedApps.isEmpty { refusedApps = [:] }
            return
        }
        enforcingTicks += 1
        guard Self.sweepIsDue(tick: enforcingTicks, enforcing: true) else { return }
        enforcingTicks = 0
        appBlocker.sweep()
        if appBlocker.refusedToQuit != refusedApps { refusedApps = appBlocker.refusedToQuit }
    }

    /// Seconds between app sweeps (the controller ticks once a second).
    nonisolated static let sweepEvery = 5

    /// Whether the app sweep runs on this tick, counted in ticks spent
    /// enforcing: every `sweepEvery`th, and never when nothing is enforcing.
    nonisolated static func sweepIsDue(tick: Int, enforcing: Bool) -> Bool {
        enforcing && tick > 0 && tick % sweepEvery == 0
    }

    /// Credits the frontmost app with the time since the last tick. A gap
    /// longer than a few seconds (a sleep, a stall) is not counted.
    private func creditForeground(since previous: Date) {
        guard recordsHistory, activityTrackingEnabled, !blocksNothing, engine.isRunning else { return }
        var seconds = now.timeIntervalSince(previous)
        if let lastAppActivation { seconds = min(seconds, max(0, now.timeIntervalSince(lastAppActivation))) }
        guard seconds > 0, seconds < 5,
              let app = NSWorkspace.shared.frontmostApplication, app.activationPolicy == .regular,
              let bundleID = app.bundleIdentifier, !Self.notWork.contains(bundleID),
              !activityExcludedApps.contains(bundleID) else {
            engine.breakActivityContinuity(at: now)
            return
        }
        let name = app.localizedName ?? bundleID
        engine.initializeActivity()
        if ActivityProbe.needsProbe(bundleID, titles: activityDocumentTitlesEnabled) { probeActivity(for: app, id: bundleID) }
        let detail: ActivityDetail?
        if let cached = activityDetailApp, cached.id == bundleID, cached.pid == app.processIdentifier,
           let at = activityDetailAt, now.timeIntervalSince(at) < 5 {
            detail = activityDetail
        } else {
            detail = nil
        }
        engine.recordActivity(appID: bundleID, appName: name,
                              site: detail?.site,
                              title: activityDocumentTitlesEnabled ? detail?.title : nil,
                              seconds: seconds, sampledAt: now)
    }

    private func invalidateActivityProbe() {
        activityProbeGeneration &+= 1
        activityDetail = nil
        activityDetailApp = nil
        activityDetailAt = nil
        activityProbeAt = nil
    }

    /// At most one selected-tab or focused-window read every four seconds.
    /// A result is usable only for the same session and same foreground PID.
    private func probeActivity(for app: NSRunningApplication, id: String) {
        guard !activityProbeInFlight,
              activityProbeAt.map({ now.timeIntervalSince($0) >= 4 }) ?? true,
              let startedAt = engine.session?.startedAt else { return }
        activityProbeInFlight = true
        activityProbeAt = now
        let generation = activityProbeGeneration
        let pid = app.processIdentifier
        let titles = activityDocumentTitlesEnabled
        activityQueue.async { [weak self] in
            let detail = ActivityProbe.detail(bundleID: id, pid: pid, titles: titles)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.activityProbeInFlight = false
                    guard self.activityProbeGeneration == generation,
                          self.recordsHistory, self.activityTrackingEnabled, !self.blocksNothing,
                          self.engine.isRunning, self.engine.session?.startedAt == startedAt,
                          self.activityDocumentTitlesEnabled == titles,
                          !self.activityExcludedApps.contains(id),
                          let front = NSWorkspace.shared.frontmostApplication,
                          front.bundleIdentifier == id, front.processIdentifier == pid else { return }
                    self.activityDetail = detail
                    self.activityDetailApp = (id, pid)
                    self.activityDetailAt = Date()
                }
            }
        }
    }

    /// Frontmost without being worked in: the lock screen and the like.
    private static let notWork: Set<String> = ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"]

    private func handle(_ event: SessionEvent) {
        switch event {
        case .started, .ended, .paused, .resumed, .undone: invalidateActivityProbe()
        default: break
        }
        var opened: (WorkspaceReport, SessionPlan)?
        switch event {
        case .started:
            guard let plan = engine.session?.plan else { break }
            if recordsHistory && activityTrackingEnabled && !blocksNothing { engine.initializeActivity() }
            // Apps and the start Shortcut run at every work start, after a
            // break too (how Apple Focus comes back on). Documents, folders
            // and pages open once, at the start the person asked for: not
            // when a break hands over to the same session again, and not
            // when a session is restored (that emits no `.started`).
            open(plan.launchApps)
            if let name = plan.startShortcut { runShortcut(name) }
            if !plan.isContinuation, !plan.resources.isEmpty {
                opened = (launcher.open(plan.resources, using: opener), plan)
            }
        case .ended(let reason, let final):
            // Not the apps whatever follows blocks again at once: a break with
            // rules, or the next block of a sequence.
            if final.plan.reopensQuitApps { reopen(Self.appsToReopen(final.quitApps, under: engine.enforcement)) }
            if let name = final.plan.endShortcut { runShortcut(name) }
            if recordsHistory, let entry = SessionEntry(ended: final, outcome: reason) {
                history.append(entry)
                historyVersion += 1
            }
            warnedSnoozes.removeAll()
        case .undone:
            // The session is back, so history must not hold it as ended: it
            // is recorded once, when it really ends. The apps and documents
            // of its start are not opened again (it never stopped being the
            // same session); only the start Shortcut runs, because the end
            // Shortcut just switched Apple Focus off.
            if let session = engine.session {
                if let entry = history.sessions.last(where: { $0.start == session.startedAt && $0.outcome == .endedEarly }),
                   history.remove(entry.id) {
                    historyVersion += 1
                }
                if let name = session.plan.startShortcut { runShortcut(name) }
            }
            // The end put blocked tabs back; the first sweep blocks them again.
            // That is the same block as before, not a new one to count or show
            // (as after a quit). Armed only when a sweep will run to clear it.
            quietsNextSweep = engine.enforcement.map { !($0.mode == .block && $0.websites.isEmpty) } ?? false
        default:
            break
        }
        applyEnforcement(sessionStarted: event == .started)
        updateClock()
        onSessionEvent(event)
        // After the session's own surfaces have reacted to the start, so a
        // card about the workspace is not dismissed by them.
        if let (report, plan) = opened { onWorkspaceOpened(report, plan) }
    }

    /// Whether the once-a-second clock is running: only while there is a
    /// session, running or paused (a paused session still has snoozes that
    /// run out), or a break. Between them Focus wakes for nothing.
    var isClockRunning: Bool { timer != nil }

    private func updateClock() {
        let needed = isStarted && (engine.session != nil || engine.isOnBreak)
        guard needed != isClockRunning else { return }
        if needed {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func runShortcut(_ name: String) {
        let previous = shortcutChain
        let opener = opener
        shortcutChain = Task {
            await previous?.value
            await opener.runShortcut(name)
        }
    }

    /// Waits for the Shortcuts started so far. For tests.
    func settleShortcuts() async {
        await shortcutChain?.value
    }

    /// Opens the session's work apps; the first comes to the front.
    private func open(_ bundleIDs: [String]) {
        guard !bundleIDs.isEmpty else { return }
        opener.openApplications(bundleIDs, activating: true)
    }

    /// Brings the blockers in line with the engine: on, off, or new rules. A
    /// session that gives way to a break with rules (or to the next block of a
    /// sequence) is one change from rule to rule: a page both block is never
    /// put back in between, one only the old rule blocked is, and one only the
    /// new rule blocks is caught by the sweep that follows.
    /// `sessionStarted`: a session has just begun. It takes stock of what is
    /// open now, as every start did when blocking stopped between sessions:
    /// an allow list hides those apps rather than quitting them. A block that
    /// follows a break with rules, or another block, inherits a running
    /// blocker, so it is restarted here; and tabs on the block page are
    /// judged again by the new session's own exceptions.
    private var enforcingOnBreak = false

    private func applyEnforcement(sessionStarted: Bool = false) {
        var target = engine.enforcement
        // Nothing is quit and no browser asked: a demo's sample break can
        // carry rules, and a rule set that is empty blocks nothing.
        if blocksNothing, target != nil { target = Enforcement(mode: .block, apps: [], websites: []) }
        let restarting = Self.restartsBlocker(sessionStarted: sessionStarted, from: enforcing, to: target)
        let phaseChanged = target != nil && engine.isOnBreak != enforcingOnBreak
        guard target != enforcing || restarting || phaseChanged else { return }
        let before = enforcing
        enforcing = target
        enforcingOnBreak = engine.isOnBreak

        guard let target else {
            appBlocker.stop()
            if Self.tabHandling(from: before, to: nil) == .restoreAll { restoreTabs(keepBlocked: nil) }
            return
        }
        if restarting { appBlocker.stop() }
        appBlocker.mode = target.mode == .block ? .block(target.apps) : .allow(target.apps)
        appBlocker.start()
        if case .keepBlocked(let rule) = Self.tabHandling(from: before, to: target) {
            restoreTabs(keepBlocked: websiteRule(for: rule))
        }
        sweepBrowsers()
    }

    /// What happens to tabs sitting on the block page when the rules change.
    enum TabHandling: Equatable, Sendable {
        /// Nothing was blocking, so no tab is on the page.
        case leave
        /// Blocking ended: every tab goes back.
        case restoreAll
        /// Rules changed: tabs the new rules no longer block go back, and
        /// those they still block stay put.
        case keepBlocked(by: Enforcement)
    }

    /// Whether a start hands over from one set of rules to another without
    /// blocking stopping in between (a break with rules, or a block straight
    /// after a block), so the blocker must start afresh to take stock of
    /// what is open now.
    nonisolated static func restartsBlocker(sessionStarted: Bool, from old: Enforcement?, to new: Enforcement?) -> Bool {
        sessionStarted && old != nil && new != nil
    }

    nonisolated static func tabHandling(from old: Enforcement?, to new: Enforcement?) -> TabHandling {
        guard old != nil else { return .leave }
        guard let new else { return .restoreAll }
        return .keepBlocked(by: new)
    }

    /// The website rule an enforcement stands for. A running session's own
    /// snoozes and its plan's website exceptions go in with it. A break's rule
    /// has neither (no session is running): it blocks what its rules list.
    nonisolated static func websiteRule(for enforcement: Enforcement, session: SessionState? = nil) -> WebsiteRule {
        WebsiteRule(enforcement: enforcement, session: session)
    }

    /// The quit apps worth opening again: not those the rules now in force
    /// would quit straight away.
    nonisolated static func appsToReopen(_ quit: [String], under enforcement: Enforcement?) -> [String] {
        guard let enforcement else { return quit }
        switch enforcement.mode {
        case .block: return quit.filter { !enforcement.apps.contains($0) }
        case .allow: return quit.filter { enforcement.apps.contains($0) }
        }
    }

    /// Quitting leaves a marker when it put tabs back from a session or a
    /// break that will resume, so the next start blocks them again quietly.
    nonisolated static func marksTabsRestored(restored: Int, hasSession: Bool, isOnBreak: Bool) -> Bool {
        marksTabsRestored(restored: restored, timedOut: false, hasSession: hasSession, isOnBreak: isOnBreak)
    }

    /// If the restore timed out the count is unknown, so the marker is written
    /// anyway when blocking will resume: at worst one quiet first sweep.
    nonisolated static func marksTabsRestored(restored: Int, timedOut: Bool, hasSession: Bool, isOnBreak: Bool) -> Bool {
        (timedOut || restored > 0) && (hasSession || isOnBreak)
    }

    /// How long quitting waits for browsers to put tabs back.
    nonisolated static let quitRestoreTimeout: TimeInterval = 3

    /// The restore's running count, shared with a queue block that may finish
    /// after quitting has stopped waiting.
    private final class RestoreCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add(_ n: Int) { lock.lock(); count += n; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// What the sweep and a restore judge tabs by. The session's snoozes and
    /// its plan's website exceptions go in; the plan is the snapshot taken
    /// when the session started, so a category edited since changes nothing.
    /// On a break there is no session, so the break's rule stands alone.
    private func websiteRule(for enforcement: Enforcement) -> WebsiteRule {
        Self.websiteRule(for: enforcement, session: engine.session)
    }

    private func sweepBrowsers() {
        guard let enforcing, !sweepInFlight else { return }
        // Nothing to find: no browser needs asking.
        if enforcing.mode == .block, enforcing.websites.isEmpty { return }
        sweepInFlight = true
        let rule = websiteRule(for: enforcing)
        let browsers = self.browsers
        let goal = engine.session?.plan.goal ?? ""
        // 0 hides the block page's Snooze: a strict session has none, and
        // neither has a break (the page would offer what nothing can do).
        let onBreak = engine.session == nil
        let minutes = onBreak || engine.session?.plan.strict == true ? 0 : Int((snoozeLength / 60).rounded())
        browserQueue.async { [weak self] in
            var redirected: [String] = []
            var access: [String: AppleEventError] = [:]
            for browser in BrowserProfile.known {
                do throws(AppleEventError) {
                    redirected += try browsers.sweep(browser, rule: rule, goal: goal, snoozeMinutes: minutes, onBreak: onBreak)
                } catch {
                    access[browser.bundleID] = error
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sweepInFlight = false
                    if self.browserAccess != access { self.browserAccess = access }
                    // Tabs put back at quit, blocked again: not a new block.
                    if self.quietsNextSweep {
                        self.quietsNextSweep = false
                    } else {
                        for key in redirected { self.report(.website(domain: key)) }
                    }
                }
            }
        }
    }

    private func restoreTabs(keepBlocked rule: WebsiteRule?) {
        let browsers = self.browsers
        let onBreak = engine.isOnBreak
        let context = BlockPageContext(goal: engine.session?.plan.goal ?? "",
                                       snoozeMinutes: onBreak || engine.session?.plan.strict == true
                                           ? 0 : Int((snoozeLength / 60).rounded()), onBreak: onBreak)
        browserQueue.async {
            for browser in BrowserProfile.known {
                _ = try? browsers.restore(browser, keepBlocked: rule, context: context)
            }
        }
    }

    private func appWasBlocked(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        let name = app.localizedName ?? bundleID
        let quit = appBlocker.action(for: app) == .terminate
        if quit { engine.recordQuit(bundleID, name: name) }
        report(.app(bundleID: bundleID, name: name, quit: quit))
    }

    /// One block, counted and shown once: a relaunch loop within a few
    /// seconds is a single block, not ten.
    private func report(_ item: BlockedItem) {
        let key = item.snoozeKey
        if let last = lastReported[key], Date().timeIntervalSince(last) < 5 { return }
        lastReported[key] = Date()
        engine.recordBlock(key, name: item.displayName)
        onBlocked(item)
    }

    private func reopen(_ bundleIDs: [String]) {
        guard !bundleIDs.isEmpty else { return }
        opener.openApplications(bundleIDs, activating: false)
    }
}
