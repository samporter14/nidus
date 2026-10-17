//
//  FocusController.swift
//  Nidus
//
//  Runs a session: drives the engine once a second, keeps the app blocker's
//  rules in step with it, sweeps the browsers off the main thread, pauses for
//  sleep, and undoes everything when the session pauses or ends. Between
//  sessions the clock is stopped and nothing runs at all.
//
//  Everything start() sets up, stop() tears down. No DroppyKit import: the
//  app wraps this.
//

import AppKit
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

    /// The break after a completed, timed session; 0 for none.
    var breakLength: TimeInterval {
        get { engine.breakLength }
        set { engine.breakLength = newValue }
    }
    static let breakWarningLead: TimeInterval = 15

    /// Finished sessions, for the stats. Recorded only while this is on.
    let history: FocusHistory
    var recordsHistory = true
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
    private var lastForegroundTick: Date?
    private var ticksSinceCheckpoint = 0
    /// Snoozes already warned about, by the end they were warned for, so a
    /// snooze taken again is warned about again.
    private var warnedSnoozes: [String: Date] = [:]
    private var warnedBreakEnd: Date?
    private var lockObservers: [NSObjectProtocol] = []
    private var isScreenLocked = false
    /// The screen is locked: someone may not be there.
    var screenIsLocked: Bool { isScreenLocked }
    /// What macOS broadcasts as the screen locks and unlocks.
    static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
    /// Shortcuts run strictly in order, so an end followed at once by a start
    /// cannot leave a Focus mode off.
    private var shortcutChain: Task<Void, Never>?

    /// `now` is the engine's clock; tests move it by hand.
    init(directory: URL, dropletID: String = "focus", now: @escaping () -> Date = Date.init) {
        blockPage = BlockPage(directory: directory, dropletID: dropletID)
        browsers = BrowserBlocker(blockPage: blockPage)
        engine = SessionEngine(store: FileSessionStore(url: directory.appendingPathComponent("session.json")), now: now)
        tabsRestoredMarker = directory.appendingPathComponent("tabs-restored")
        history = FocusHistory(url: directory.appendingPathComponent("history.json"))
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        try? blockPage.install()
        engine.onEvent = { [weak self] event in self?.handle(event) }
        now = Date()
        engine.restore()
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
            // Synchronous, after any sweep in flight: the process is about
            // to end. Every Apple Event has a timeout, so a hung browser
            // costs seconds, not the quit.
            let browsers = self.browsers
            let restored = browserQueue.sync {
                BrowserProfile.known.reduce(0) { count, browser in
                    count + ((try? browsers.restore(browser))?.count ?? 0)
                }
            }
            if Self.marksTabsRestored(restored: restored, hasSession: engine.session != nil, isOnBreak: engine.isOnBreak) {
                FileManager.default.createFile(atPath: tabsRestoredMarker.path, contents: Data())
            }
        }
        isStarted = false
        updateClock()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        lockObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        lockObservers.removeAll()
        appBlocker.stop()
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

    func clearHistory() {
        history.clear()
        historyVersion += 1
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
        ticksSinceCheckpoint += 1
        if ticksSinceCheckpoint >= 15, engine.session != nil {
            ticksSinceCheckpoint = 0
            engine.checkpoint()
        }
    }

    /// Credits the frontmost app with the time since the last tick. A gap
    /// longer than a few seconds (a sleep, a stall) is not counted.
    private func creditForeground(since previous: Date) {
        guard engine.isRunning else { return }
        let seconds = now.timeIntervalSince(previous)
        guard seconds > 0, seconds < 5,
              let app = NSWorkspace.shared.frontmostApplication, app.activationPolicy == .regular,
              let bundleID = app.bundleIdentifier, !Self.notWork.contains(bundleID) else { return }
        engine.recordForeground(bundleID, name: app.localizedName ?? bundleID, seconds: seconds)
    }

    /// Frontmost without being worked in: the lock screen and the like.
    private static let notWork: Set<String> = ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"]

    private func handle(_ event: SessionEvent) {
        var opened: (WorkspaceReport, SessionPlan)?
        switch event {
        case .started:
            guard let plan = engine.session?.plan else { break }
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
        default:
            break
        }
        applyEnforcement()
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
    private func applyEnforcement() {
        var target = engine.enforcement
        // Nothing is quit and no browser asked: a demo's sample break can
        // carry rules, and a rule set that is empty blocks nothing.
        if blocksNothing, target != nil { target = Enforcement(mode: .block, apps: [], websites: []) }
        guard target != enforcing else { return }
        let before = enforcing
        enforcing = target

        guard let target else {
            appBlocker.stop()
            if Self.tabHandling(from: before, to: nil) == .restoreAll { restoreTabs(keepBlocked: nil) }
            return
        }
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
        restored > 0 && (hasSession || isOnBreak)
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
        browserQueue.async {
            for browser in BrowserProfile.known {
                _ = try? browsers.restore(browser, keepBlocked: rule)
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
