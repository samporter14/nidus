//
//  NidusModel.swift
//  Nidus
//
//  The model: wires FocusController (Core/, no UI) to the app's surfaces
//  (the menu bar item and its popover, the cards, Settings) and keeps the
//  user's settings. Each surface lives in its own file.
//

import Combine
import SwiftUI

/// Blocks distracting apps and websites for a set time.
@MainActor
final class NidusModel: NSObject, ObservableObject {
    /// The block page's folder name and the id the core was written with.
    nonisolated static let id = "focus"

    private(set) var host: NidusHost?
    private(set) var controller: FocusController?
    private var subscriptions: Set<AnyCancellable> = []
    private var menuBar: FocusMenuBar?
    var menuBarItem: FocusMenuBar? { menuBar }
    /// The last focus state written, so a write happens only on a change.
    fileprivate var lastPublishedFocus: FocusFile?

    /// The goal typed into the popover, kept while it closes and opens.
    @Published var goalDraft = ""

    /// A time of day to work until ("until 3:30"), for the next Start only.
    /// Never saved: as a number of minutes it would be wrong tomorrow. A
    /// Start, or choosing any saved length, clears it; see FocusLength.swift.
    /// Whatever else offers an end time ("Until next meeting") sets this.
    @Published var untilTarget: Date?

    /// The popover's "Custom…" length field: nil while it is closed.
    @Published var customLengthDraft: CustomLengthDraft?

    /// Demo only (`--demo <scenario>`): a state to open in (`running`,
    /// `paused`, `open-ended`, `blocked`, `wrapup`), so every surface can be
    /// seen with a session. Its sample session blocks nothing. `welcome`
    /// shows the first-run card and guide.
    var harnessScenario: String?

    /// Demo only: open the popover on a strict session's end phrase.
    var harnessOpensStrictEnd: Bool { harnessScenario == "strict-end" }

    /// The welcome card waits a moment after activation; cancelled if Focus
    /// is switched off first.
    private var welcomeTask: Task<Void, Never>?
    /// Browsers already warned about this session, so each is said once.
    private var warnedBrowsers: Set<String> = []
    /// The last recorded session with a goal, until "did you finish?" is
    /// answered or the next session starts. The menu bar asks too.
    private(set) var pendingFinish: (id: SessionEntry.ID, goal: String)?
    /// Listens for the moments Monday's recap may be offered (WeeklyRecapCard.swift).
    var recapWatcher: WeeklyRecapWatcher?
    /// What the cards remember: a snooze waiting out its pause, and the
    /// answer to "did you finish?" the wrap-up card is showing. FocusSurfaces.
    let cards = FocusCardState()

    // MARK: Lifecycle

    func activate(host: NidusHost) {
        self.host = host
        let controller = FocusController(directory: host.environment.containerDirectory,
                                         dropletID: Self.id)
        self.controller = controller
        applySettings()

        controller.onBlocked = { [weak self] item in
            self?.presentBlockedHUD(for: item)
            self?.menuBar?.flinch()
        }
        controller.onSessionEvent = { [weak self] event in self?.sessionDidChange(event) }
        controller.onSnoozeEnding = { [weak self] item, end in self?.presentSnoozeEndingHUD(for: item, at: end) }
        controller.onBreakEnding = { [weak self] end, plan in self?.presentBreakEndingHUD(at: end, next: plan) }
        // Views observe the model; forward the controller's once-a-second
        // clock and the preferences, so one object drives every surface.
        controller.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        controller.$now
            // @Published sends before the value changes; wait a turn so
            // what the menu bar reads is the new second, as the views do.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.menuBar?.sync()
                // Adding time moves the end without a session event; this
                // writes only when the end or the state changed.
                self?.publishFocus()
            }
            .store(in: &subscriptions)
        controller.$browserAccess
            .receive(on: DispatchQueue.main)
            .sink { [weak self] access in self?.browserAccessDidChange(access) }
            .store(in: &subscriptions)
        host.preferences.didChange
            .sink { [weak self] _ in
                self?.applySettings()
                self?.menuBar?.sync()
                self?.objectWillChange.send()
            }
            .store(in: &subscriptions)

        controller.start()
        publishFocus()
        startWeeklyRecap()

        if host.isGranted(.menuBar) {
            let menuBar = FocusMenuBar(model: self)
            menuBar.start()
            self.menuBar = menuBar
        }

        if let harnessScenario {
            runHarnessScenario(harnessScenario)
        } else if !hasBeenWelcomed, !hasStartedASession {
            // Once, on a first install. Anyone updating has started a session.
            hasBeenWelcomed = true
            welcomeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self?.presentWelcomeHUD()
            }
        }
    }

    func deactivate() {
        publishFocus(quitting: true)
        // Everything activate() started is torn down here, before Nidus quits.
        welcomeTask?.cancel()
        welcomeTask = nil
        stopWeeklyRecap()
        for id in [Self.welcomeHUDID, Self.browserHUDID, Self.snoozeHUDID, Self.snoozeWaitHUDID, Self.breakHUDID] { host?.hud.dismiss(id: id) }
        controller?.stop()
        controller = nil
        menuBar?.stop()
        menuBar = nil
        subscriptions.removeAll()
        host?.hud.dismiss(id: Self.blockedHUDID)
        host = nil
    }

    // MARK: Session commands

    var engine: SessionEngine? { controller?.engine }
    var isActive: Bool { engine?.session != nil }
    var isPaused: Bool { engine?.isPaused ?? false }

    /// Starts a session from the popover: its goal, length and categories.
    func startSession() {
        startSession(SessionRequest(goal: goalDraft))
    }

    /// Starts a session from anywhere: the popover, a nidus:// link, a
    /// Shortcuts action, a saved setup or a schedule. What the request leaves
    /// nil comes from the popover's current choices and Settings, except the
    /// goal: nil is none, so a half-typed goal is never taken. Returns
    /// false, starting nothing, while a session or break is already on, or
    /// when a block list session would block nothing.
    @discardableResult
    func startSession(_ request: SessionRequest) -> Bool {
        guard let controller, !isActive, !isOnBreak else { return false }
        let mode = request.mode ?? mode
        let ids = request.categoryIDs ?? selectedCategoryIDs
        let chosen = categories.filter { ids.contains($0.id) }
        guard mode == .allow || !chosen.allSatisfy(\.isEmpty) else { return false }
        let minutes = request.minutes ?? minutesForNextStart()
        var plan = SessionPlan(
            goal: (request.goal ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            duration: minutes > 0 ? TimeInterval(minutes * 60) : nil,
            mode: mode,
            categories: chosen,
            reopensQuitApps: reopensQuitApps,
            launchApps: launchApps.map(\.bundleID),
            startShortcut: startShortcut,
            endShortcut: endShortcut
        )
        plan.strict = request.strict ?? strictMode
        controller.start(plan)
        rememberGoal(plan.goal)
        host?.feedback.play(.success)
        askBrowsersNeedingConsent()
        return true
    }

    /// Starts the last session again, from the wrap-up card.
    func startAgain() {
        guard let controller, let last = controller.engine.lastPlan else { return startSession() }
        controller.start(last)
        host?.feedback.play(.success)
        askBrowsersNeedingConsent()
    }

    /// The shortcut: ends a running session, or starts the last one again.
    /// A strict session is ended only from the popover, and a break's
    /// session starts at once.
    func toggleSession() {
        guard let controller else { return }
        if isActive, isStrict {
            presentStrictHUD()
        } else if isActive {
            controller.end()
        } else if isOnBreak {
            skipBreak()
        } else if let last = controller.engine.lastPlan {
            controller.start(last)
            host?.feedback.play(.success)
            askBrowsersNeedingConsent()
        } else {
            startSession()
        }
    }

    /// Starts the next session now instead of finishing the break.
    func skipBreak() {
        controller?.skipBreak()
        host?.hud.dismiss(id: Self.breakHUDID)
        host?.feedback.play(.success)
    }

    /// Stops after the break: no session follows.
    func endBreak() {
        controller?.endBreak()
        host?.hud.dismiss(id: Self.breakHUDID)
    }

    /// "Did you finish?", from the wrap-up card or the menu bar. The card, if
    /// it is still up, turns into its confirmation and stays a few seconds
    /// to be read; the menu bar's items go with `pendingFinish`.
    func answerFinished(_ finished: Bool) {
        guard let pending = pendingFinish else { return }
        controller?.markFinished(pending.id, finished)
        pendingFinish = nil
        cards.finishAnswer = finished
        host?.hud.refresh(id: Self.completedHUDID, duration: FinishReply.linger,
                          announcing: FinishReply.confirmation(finished))
        host?.feedback.play(finished ? .success : .tick)
    }

    func togglePause() {
        isPaused ? controller?.resume() : controller?.pause()
    }

    func addTime() { controller?.extend(by: 5 * 60) }
    func endSession() { controller?.end() }

    func snooze(_ key: String) {
        controller?.snooze(key)
        host?.hud.dismiss(id: Self.blockedHUDID)
    }

    func openSettings() { host?.workspace.openSettings() }

    /// A field that has just appeared takes keystrokes only while Nidus is
    /// the active app; the popover makes it so when it opens.
    /// Not for a render, which draws off-screen and must not take the
    /// keyboard from whatever is being typed in.
    func requestKeyboardFocus() { if !CaptureSurfaces.isActive, !RenderSurfaces.isActive { NSApp.activate() } }

    func runHarnessScenario(_ scenario: String) {
        guard let controller else { return }
        switch scenario {
        case "idle", "stats": return controller.end()
        case "stats-filled": controller.end(); return seedSampleHistory()
        case "recap": controller.end(); return presentSampleRecap()
        case "break":
            controller.end()
            let next = SessionPlan(goal: "Write the launch post", duration: 25 * 60, mode: .block, apps: [], websites: [])
            controller.engine.startBreak(plan: next, length: 5 * 60)
            presentBreakEndingHUD(at: Date().addingTimeInterval(12), next: next)
            return
        case "welcome": controller.end(); return presentWelcomeHUD()
        case "setups": controller.end(); return seedSampleSetups()
        case "goals":
            controller.end()
            if recentGoals.isEmpty {
                recentGoals = ["Write the launch post", "Chapter three", "Fix the sync bug"]
            }
            return
        default: break
        }
        // The cards reuse a session the harness restored, so they can be
        // shown partway through one; everything else starts afresh.
        if controller.engine.session == nil || !["blocked", "wrapup"].contains(scenario) {
            controller.start(SessionPlan(goal: "Write the launch post",
                                         duration: scenario == "open-ended" ? nil : 25 * 60,
                                         mode: .block, apps: [], websites: [],
                                         strict: scenario.hasPrefix("strict")))
        }
        switch scenario {
        case "paused": controller.pause()
        case "blocked": presentBlockedHUD(for: .app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", quit: true))
        case "finish", "finish-yes", "finish-notyet", "finish-break", "finish-break-yes":
            // The card asking, then as it reads after Yes or Not yet; and the
            // same while a break follows.
            guard var final = controller.engine.session else { break }
            final.focusedTime = 25 * 60
            final.blocks = ["youtube.com": 3, "com.tinyspeck.slackmacgap": 1]
            if scenario.hasPrefix("finish-break") {
                controller.end()
                controller.engine.startBreak(plan: final.plan, length: 5 * 60)
            }
            pendingFinish = (id: UUID(), goal: final.plan.goal)
            presentWrapUpHUD(for: final, completed: true, askAbout: final.plan.goal)
            if scenario.hasSuffix("-yes") { answerFinished(true) }
            if scenario == "finish-notyet" { answerFinished(false) }
        case "wrapup", "streak":
            guard var final = controller.engine.session else { break }
            final.focusedTime = 25 * 60
            final.blocks = ["youtube.com": 3, "com.tinyspeck.slackmacgap": 1]
            presentWrapUpHUD(for: final, completed: true, streak: scenario == "streak" ? 12 : nil)
        case "browser":
            presentBrowserAccessHUD(for: .chrome, needsConsent: true)
        case "strict":
            presentBlockedHUD(for: .app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", quit: true))
        case "wrapup-break":
            guard var final = controller.engine.session else { break }
            final.focusedTime = 25 * 60
            final.blocks = ["youtube.com": 3, "com.tinyspeck.slackmacgap": 1]
            controller.end()
            controller.engine.startBreak(plan: final.plan, length: 5 * 60)
            presentWrapUpHUD(for: final, completed: true)
        case "snooze":
            controller.engine.recordBlock("youtube.com", name: "youtube.com")
            controller.snooze("youtube.com")
            if let end = controller.engine.session?.snoozes["youtube.com"] {
                presentSnoozeEndingHUD(for: "youtube.com", at: min(end, Date().addingTimeInterval(30)))
            }
        default: runCardScenario(scenario)
        }
    }

    // MARK: Session events

    private func sessionDidChange(_ event: SessionEvent) {
        defer { publishFocus() }
        dropSnoozeWaitIfMoot()
        switch event {
        case .started:
            warnedBrowsers.removeAll()
            pendingFinish = nil
            // A one-off belongs to the Start it was set for, however it came.
            untilTarget = nil
            customLengthDraft = nil
            // Its question has no answer to take now.
            host?.hud.dismiss(id: Self.completedHUDID)
            host?.hud.dismiss(id: Self.breakHUDID)
            // Last week's recap can wait; this session is now.
            host?.hud.dismiss(id: Self.recapHUDID)
            menuBar?.closePopover()
            menuBar?.sessionDidStart()
        case .ended(let reason, let final):
            host?.hud.dismiss(id: Self.snoozeHUDID)
            if reason != .expiredWhileAway {
                // Ask only about a goal that was set and a session that was
                // recorded: the answer is kept with it.
                let entry = controller?.history.sessions.last(where: { $0.start == final.startedAt })
                pendingFinish = entry.flatMap { $0.goal.isEmpty ? nil : (id: $0.id, goal: $0.goal) }
                presentWrapUpHUD(for: final, completed: reason == .completed, streak: streakMilestone(for: final),
                                 askAbout: pendingFinish?.goal)
            }
            goalDraft = ""
            menuBar?.sessionDidEnd(completed: reason == .completed)
        case .paused, .resumed, .breakEnded:
            menuBar?.sync()
        default:
            break
        }
        objectWillChange.send()
    }

    // MARK: Reading the clock

    var remaining: TimeInterval { engine?.remaining ?? 0 }
    var isOnBreak: Bool { engine?.isOnBreak ?? false }
    /// The running session is strict: no snooze, no pause, ending early is
    /// gated in the popover.
    var isStrict: Bool { engine?.session?.plan.strict ?? false }
    var breakRemaining: TimeInterval { engine?.breakRemaining ?? 0 }
    /// 0 to 1, how much of the break is over.
    var breakProgress: Double {
        guard let pause = engine?.breakState, pause.length > 0 else { return 0 }
        return min(1, max(0, 1 - breakRemaining / pause.length))
    }
    /// What starts when the break ends.
    var nextGoal: String { engine?.breakState?.plan.goal ?? "" }
    var elapsed: TimeInterval { engine?.elapsed ?? 0 }
    var isOpenEnded: Bool { engine?.session?.plan.duration == nil }
    var goal: String { engine?.session?.plan.goal ?? "" }

    /// 0 to 1, how much of the session is done; open-ended sessions have none.
    var progress: Double {
        guard let session = engine?.session, session.plan.duration != nil, session.budget > 0 else { return 0 }
        return min(1, max(0, elapsed / session.budget))
    }

    /// The time the surfaces show: left for a timed session, elapsed for an
    /// open-ended one.
    var clockText: String {
        if isOnBreak { return FocusFormat.clock(breakRemaining) }
        return FocusFormat.clock(isOpenEnded ? elapsed : remaining)
    }
}

// MARK: - Settings

extension NidusModel {
    enum Key {
        static let categories = "categories"
        static let selection = "selectedCategories"
        static let durationMinutes = "durationMinutes"
        static let mode = "mode"
        static let appAction = "appAction"
        static let snoozeMinutes = "snoozeMinutes"
        static let reopensQuitApps = "reopensQuitApps"
        static let launchApps = "launchApps"
        static let startShortcut = "startShortcut"
        static let endShortcut = "endShortcut"
        static let recordsHistory = "recordsHistory"
        static let welcomed = "welcomed"
        static let menuBarShowsTime = "menuBarShowsTime"
        static let recentGoals = "recentGoals"
        static let strictMode = "strictMode"
        static let breakMinutes = "breakMinutes"
        static let hidesGettingStarted = "hidesGettingStarted"
    }

    /// 0 means open-ended.
    static let durationChoices = [15, 25, 45, 60, 90, 0]
    static let snoozeChoices = [1, 3, 5, 10]
    /// 0 means no break.
    static let breakChoices = [0, 5, 10, 15]

    func preference<Value: Codable>(_ key: String, default value: Value) -> Value {
        host?.preferences.value(forKey: key, default: value) ?? value
    }

    func setPreference<Value: Codable>(_ value: Value, _ key: String) {
        host?.preferences.setValue(value, forKey: key)
        objectWillChange.send()
    }

    var categories: [FocusCategory] {
        get { preference(Key.categories, default: FocusCategory.presets) }
        set { setPreference(newValue, Key.categories) }
    }

    var selectedCategoryIDs: [String] {
        get { preference(Key.selection, default: FocusCategory.defaultSelection) }
        set { setPreference(newValue, Key.selection) }
    }

    var selectedCategories: [FocusCategory] {
        categories.filter { selectedCategoryIDs.contains($0.id) }
    }

    var durationMinutes: Int {
        get { preference(Key.durationMinutes, default: 25) }
        set {
            setPreference(newValue, Key.durationMinutes)
            // Another length was chosen, here or in Settings.
            untilTarget = nil
        }
    }

    var defaultDuration: TimeInterval? {
        durationMinutes == 0 ? nil : TimeInterval(durationMinutes * 60)
    }

    var mode: SessionPlan.Mode {
        get { SessionPlan.Mode(rawValue: preference(Key.mode, default: "block")) ?? .block }
        set { setPreference(newValue.rawValue, Key.mode) }
    }

    var hidesInsteadOfQuitting: Bool {
        get { preference(Key.appAction, default: "quit") == "hide" }
        set { setPreference(newValue ? "hide" : "quit", Key.appAction) }
    }

    var snoozeMinutes: Int {
        get { preference(Key.snoozeMinutes, default: 3) }
        set { setPreference(newValue, Key.snoozeMinutes) }
    }

    var reopensQuitApps: Bool {
        get { preference(Key.reopensQuitApps, default: false) }
        set { setPreference(newValue, Key.reopensQuitApps) }
    }

    /// Opened when a session starts, and never blocked by it.
    var launchApps: [BlockedApp] {
        get { preference(Key.launchApps, default: [BlockedApp]()) }
        set { setPreference(newValue, Key.launchApps) }
    }

    /// Shortcut names; empty means none.
    var startShortcut: String? {
        get { let v = preference(Key.startShortcut, default: ""); return v.isEmpty ? nil : v }
        set { setPreference(newValue ?? "", Key.startShortcut) }
    }

    var endShortcut: String? {
        get { let v = preference(Key.endShortcut, default: ""); return v.isEmpty ? nil : v }
        set { setPreference(newValue ?? "", Key.endShortcut) }
    }

    var recordsHistory: Bool {
        get { preference(Key.recordsHistory, default: true) }
        set { setPreference(newValue, Key.recordsHistory) }
    }

    /// Sessions started from now on are strict. Off by default.
    var strictMode: Bool {
        get { preference(Key.strictMode, default: false) }
        set { setPreference(newValue, Key.strictMode) }
    }

    /// Minutes of break after a session that runs its full length; 0 for none.
    var breakMinutes: Int {
        get { preference(Key.breakMinutes, default: 0) }
        set { setPreference(newValue, Key.breakMinutes) }
    }

    /// The time left beside the menu bar glyph while a session runs. Off by
    /// default: the filling brain is the clock.
    var menuBarShowsTime: Bool {
        get { preference(Key.menuBarShowsTime, default: false) }
        set { setPreference(newValue, Key.menuBarShowsTime); menuBar?.sync() }
    }

    /// The last few goals, newest first, offered in the goal field. Kept only
    /// while sessions are recorded, and cleared with the history.
    var recentGoals: [String] {
        get { preference(Key.recentGoals, default: [String]()) }
        set { setPreference(newValue, Key.recentGoals) }
    }

    static let recentGoalLimit = 5

    fileprivate func rememberGoal(_ goal: String) {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard recordsHistory, !goal.isEmpty else { return }
        var goals = recentGoals.filter { $0.caseInsensitiveCompare(goal) != .orderedSame }
        goals.insert(goal, at: 0)
        recentGoals = Array(goals.prefix(Self.recentGoalLimit))
    }

    /// Set once the first-run card has been shown.
    var hasBeenWelcomed: Bool {
        get { preference(Key.welcomed, default: false) }
        set { setPreference(newValue, Key.welcomed) }
    }

    /// A session was ever started here: one is saved as the last, or the
    /// history has one.
    var hasStartedASession: Bool {
        guard let controller else { return false }
        return controller.engine.lastPlan != nil || !controller.history.sessions.isEmpty
    }

    /// The Get started guide at the top of Settings: until the first session
    /// starts, or until it is closed.
    var showsGettingStarted: Bool {
        if harnessScenario == "welcome" { return true }
        return !preference(Key.hidesGettingStarted, default: false) && !hasStartedASession
    }

    func hideGettingStarted() { setPreference(true, Key.hidesGettingStarted) }

    func isSelected(_ category: FocusCategory) -> Bool {
        selectedCategoryIDs.contains(category.id)
    }

    func toggleSelection(_ category: FocusCategory) {
        var ids = selectedCategoryIDs
        if let index = ids.firstIndex(of: category.id) { ids.remove(at: index) } else { ids.append(category.id) }
        selectedCategoryIDs = ids
    }

    /// "Social, Video", or a count once the names stop fitting.
    var selectionSummary: String {
        let names = selectedCategories.map(\.name)
        switch names.count {
        case 0: return "Nothing selected"
        case 1, 2: return names.joined(separator: ", ")
        default: return "\(names.count) categories"
        }
    }

    func binding<Value>(_ keyPath: ReferenceWritableKeyPath<NidusModel, Value>) -> Binding<Value> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }

    private func applySettings() {
        controller?.appAction = hidesInsteadOfQuitting ? .hide : .terminate
        controller?.snoozeLength = TimeInterval(snoozeMinutes * 60)
        controller?.recordsHistory = recordsHistory
        controller?.breakLength = TimeInterval(breakMinutes * 60)
    }

    /// The stats, worked out fresh each time the page draws.
    var stats: FocusStats {
        FocusStats(sessions: controller?.history.sessions ?? [])
    }

    func clearHistory() {
        controller?.clearHistory()
        recentGoals = []
    }

    /// The streak the session that just ended carried on, if it was the
    /// day's first and was recorded.
    private func streakMilestone(for final: SessionState) -> Int? {
        guard let sessions = controller?.history.sessions,
              let entry = sessions.last(where: { $0.start == final.startedAt }) else { return nil }
        return FocusStats.streakMilestone(for: entry, in: sessions)
    }

    // MARK: Browsers

    /// Mid-session, the first time a running browser refuses Focus, say so.
    private func browserAccessDidChange(_ access: [String: AppleEventError]) {
        for browser in BrowserProfile.known {
            let state = access[browser.bundleID].map { "\($0)" } ?? "ok or not running"
            host?.log.notice("Browser \(browser.bundleID, privacy: .public): \(state, privacy: .public)")
        }
        guard isActive else { return }
        for browser in BrowserProfile.known where !warnedBrowsers.contains(browser.bundleID) {
            guard let error = access[browser.bundleID], error == .notPermitted || error == .needsConsent else { continue }
            warnedBrowsers.insert(browser.bundleID)
            presentBrowserAccessHUD(for: browser, needsConsent: error == .needsConsent)
            return
        }
    }

    /// Starting a session is a click, so it is the moment to ask macOS, once,
    /// for each open browser Nidus has never been allowed or refused: until
    /// then, websites in it can't be blocked. The prompts come from macOS,
    /// one at a time, off the main thread.
    func askBrowsersNeedingConsent() {
        let log = host?.log
        Task.detached(priority: .userInitiated) {
            for browser in BrowserProfile.known {
                guard let target = AppleEventTarget(runningBundleID: browser.bundleID),
                      target.automationPermission(ask: false) == .needsConsent else { continue }
                log?.notice("Asking macOS to let Nidus control \(browser.bundleID, privacy: .public)")
                let answer = target.automationPermission(ask: true)
                log?.notice("\(browser.bundleID, privacy: .public) answered: \(answer.map { "\($0)" } ?? "allowed", privacy: .public)")
            }
        }
    }

    /// Raises macOS's Automation prompt for one browser. It blocks until
    /// answered, so it is asked off the main thread, and only ever from a
    /// click: the Allow button in Settings or on the card.
    func askBrowserAccess(_ browser: BrowserProfile, then done: @escaping @MainActor () -> Void = {}) {
        guard let target = AppleEventTarget(runningBundleID: browser.bundleID) else { return done() }
        Task.detached(priority: .userInitiated) {
            _ = target.automationPermission(ask: true)
            await MainActor.run { done() }
        }
    }

    /// System Settings, Privacy & Security, Automation.
    func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    func openStats() { host?.workspace.openSettingsPage("stats", title: "Stats") }
}

// MARK: - Formatting

enum FocusFormat {
    /// "18:42", or "1:05:00" past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// "25 min", "1 hr 30 min", "Open-ended".
    static func duration(minutes: Int) -> String {
        guard minutes > 0 else { return "Open-ended" }
        let hours = minutes / 60, rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest) min"
        case (_, 0): return "\(hours) hr"
        default: return "\(hours) hr \(rest) min"
        }
    }

    /// "18 min left", where space is short.
    static func short(_ seconds: TimeInterval) -> String {
        "\(max(1, Int((seconds / 60).rounded(.up)))) min left"
    }

    /// "18 minutes left", for accessibility.
    static func spoken(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes") left"
    }
}

// MARK: - Telling other apps

extension NidusModel {
    /// Writes `focus.json` beside the session and says so on this Mac
    /// (`local.sam.nidus.focus`), for other Solanum apps: Bench holds its
    /// "Finished" cards while a session runs. Only whether one runs and until
    /// when; never the goal or what is blocked. Paused or on a break is not
    /// focusing. Demos and captures publish nothing.
    func publishFocus(quitting: Bool = false) {
        guard !Demo.isActive, let host else { return }
        let focusing = !quitting && isActive && !isPaused
        let until: Double? = focusing && !isOpenEnded
            ? Date().addingTimeInterval(remaining).timeIntervalSince1970.rounded()
            : nil
        let state = FocusFile(version: 1, focusing: focusing, until: until)
        guard state != lastPublishedFocus else { return }
        lastPublishedFocus = state
        let url = host.environment.containerDirectory.appendingPathComponent("focus.json")
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: url, options: .atomic) }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("local.sam.nidus.focus"), object: nil, userInfo: nil, deliverImmediately: true)
    }
}

/// A session to start. Anything nil is taken from the popover's current
/// choices (length, categories) and Settings (mode, strict); a nil goal is
/// no goal.
struct SessionRequest: Equatable, Sendable {
    var goal: String?
    /// 0 means open-ended.
    var minutes: Int?
    /// FocusCategory ids.
    var categoryIDs: [String]?
    var mode: SessionPlan.Mode?
    var strict: Bool?
}

/// What `focus.json` holds.
struct FocusFile: Codable, Equatable {
    var version: Int
    var focusing: Bool
    /// Seconds since 1970; nil for an open-ended session or when not focusing.
    var until: Double?
}

