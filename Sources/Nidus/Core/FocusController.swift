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

    var onBlocked: (BlockedItem) -> Void = { _ in }
    var onSessionEvent: (SessionEvent) -> Void = { _ in }
    /// A snooze is about to run out: the item, and when.
    var onSnoozeEnding: (String, Date) -> Void = { _, _ in }
    /// A break is about to end and the next session start: when, and what.
    var onBreakEnding: (Date, SessionPlan) -> Void = { _, _ in }

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
    /// What macOS broadcasts as the screen locks and unlocks.
    static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
    /// Shortcuts run strictly in order, so an end followed at once by a start
    /// cannot leave a Focus mode off.
    private var shortcutChain: Task<Void, Never>?

    init(directory: URL, dropletID: String = "focus") {
        blockPage = BlockPage(directory: directory, dropletID: dropletID)
        browsers = BrowserBlocker(blockPage: blockPage)
        engine = SessionEngine(store: FileSessionStore(url: directory.appendingPathComponent("session.json")))
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
    /// start(), so this does not end it, and the tabs stay on the block page
    /// until then: they are the session's, not this process's.
    func stop() {
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
        switch event {
        case .started:
            guard let plan = engine.session?.plan else { break }
            open(plan.launchApps)
            if let name = plan.startShortcut { runShortcut(name) }
        case .ended(let reason, let final):
            if final.plan.reopensQuitApps { reopen(final.quitApps) }
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
        shortcutChain = Task {
            await previous?.value
            await FocusShortcuts.run(name)
        }
    }

    /// Opens the session's work apps; the first comes to the front.
    private func open(_ bundleIDs: [String]) {
        for (index, bundleID) in bundleIDs.enumerated() {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = index == 0
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    /// Brings the blockers in line with the engine: on, off, or new rules.
    private func applyEnforcement() {
        let target = engine.enforcement
        guard target != enforcing else { return }
        let wasEnforcing = enforcing != nil
        enforcing = target

        guard let target else {
            appBlocker.stop()
            if wasEnforcing { restoreTabs(keepBlocked: nil) }
            return
        }
        appBlocker.mode = target.mode == .block ? .block(target.apps) : .allow(target.apps)
        appBlocker.start()
        // A snooze narrows the rule: put back the tabs it no longer blocks.
        if wasEnforcing { restoreTabs(keepBlocked: websiteRule(for: target)) }
        sweepBrowsers()
    }

    private func websiteRule(for enforcement: Enforcement) -> WebsiteRule {
        // Snoozed sites on the plan, so a snooze covers a listed entry that
        // overlaps another (`youtube.com/shorts` inside `youtube.com`).
        let snoozed = engine.session.map { Set($0.snoozes.keys).intersection($0.plan.websites) } ?? []
        return WebsiteRule(mode: enforcement.mode == .block ? .block : .allow,
                           domains: Array(enforcement.websites), snoozed: Array(snoozed))
    }

    private func sweepBrowsers() {
        guard let enforcing, !sweepInFlight else { return }
        // Nothing to find: no browser needs asking.
        if enforcing.mode == .block, enforcing.websites.isEmpty { return }
        sweepInFlight = true
        let rule = websiteRule(for: enforcing)
        let browsers = self.browsers
        let goal = engine.session?.plan.goal ?? ""
        // 0 hides the block page's Snooze: a strict session has none.
        let minutes = engine.session?.plan.strict == true ? 0 : Int((snoozeLength / 60).rounded())
        browserQueue.async { [weak self] in
            var redirected: [String] = []
            var access: [String: AppleEventError] = [:]
            for browser in BrowserProfile.known {
                do throws(AppleEventError) {
                    redirected += try browsers.sweep(browser, rule: rule, goal: goal, snoozeMinutes: minutes)
                } catch {
                    access[browser.bundleID] = error
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sweepInFlight = false
                    if self.browserAccess != access { self.browserAccess = access }
                    for key in redirected { self.report(.website(domain: key)) }
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
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        for bundleID in bundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }
}
