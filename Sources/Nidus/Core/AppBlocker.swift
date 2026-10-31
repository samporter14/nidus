//
//  AppBlocker.swift
//  Nidus
//
//  Quits (or hides) blocked apps each time they launch or come to the front.
//  terminate() asks the app to quit the normal way, so it can save or refuse;
//  forceTerminate() is never used, because it loses unsaved work.
//

import AppKit

@MainActor
final class AppBlocker {
    enum Mode: Sendable, Equatable {
        /// Only these bundle IDs are blocked.
        case block(Set<String>)
        /// Everything except these (and `exempt`) is blocked.
        case allow(Set<String>)
    }

    enum Action: Sendable {
        case terminate
        case hide
    }

    /// System apps that are never blocked, whatever the mode. Nidus itself
    /// is protected separately by `Bundle.main.bundleIdentifier`.
    nonisolated static let exempt: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systempreferences",
        "com.apple.loginwindow",
        "com.apple.SecurityAgent",
        "com.apple.ActivityMonitor",
    ]

    /// Changing it applies at once to apps already running.
    var mode: Mode {
        didSet { if mode != oldValue, !observers.isEmpty { enforceRunningApps() } }
    }
    var action: Action
    private let onBlock: (NSRunningApplication) -> Void
    private var observers: [NSObjectProtocol] = []
    /// Apps already open when blocking started. In allow mode these are only
    /// ever hidden: that mode covers every app not listed, and quitting all
    /// of them at once would put an unsaved-changes prompt in front of the
    /// user for each one. Apps launched during the session are quit.
    private var openAtStart: Set<pid_t> = []
    /// Apps that should have quit and are still running, found by `sweep()`
    /// (bundle ID to name). Rebuilt on every sweep, so an app leaves it when it
    /// quits, when it is no longer blocked (snooze, rule change), and when the
    /// blocker stops. Only the `.terminate` action fills it: a hidden app is
    /// doing what a `.hide` rule asks.
    private(set) var refusedToQuit: [String: String] = [:]
    /// An app launched this recently may still be inside `retryQuit`'s 1, 3, 6
    /// second sequence, so it is not yet called a refusal.
    nonisolated static let refusalGrace: TimeInterval = 7

    init(mode: Mode, action: Action, onBlock: @escaping (NSRunningApplication) -> Void = { _ in }) {
        self.mode = mode
        self.action = action
        self.onBlock = onBlock
    }

    func isBlocked(_ bundleID: String) -> Bool {
        Self.isBlocked(bundleID, under: mode)
    }

    /// The one rule for whether an app is blocked under a mode, for the
    /// blocker and for whatever wants to say beforehand what it would do.
    nonisolated static func isBlocked(_ bundleID: String, under mode: Mode) -> Bool {
        if exempt.contains(bundleID) || bundleID == Bundle.main.bundleIdentifier { return false }
        switch mode {
        case .block(let blocked): return blocked.contains(bundleID)
        case .allow(let allowed): return !allowed.contains(bundleID)
        }
    }

    /// Starts watching, and deals with blocked apps that are already running.
    func start() {
        guard observers.isEmpty else { return }
        openAtStart = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.enforce(app) }
            })
        }
        enforceRunningApps()
    }

    func enforceRunningApps() {
        NSWorkspace.shared.runningApplications.forEach(enforce)
    }

    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        openAtStart.removeAll()
        refusedToQuit.removeAll()
    }

    /// What to do with this app: the chosen action, except that allow mode
    /// only hides what was already open.
    func action(for app: NSRunningApplication) -> Action {
        if case .allow = mode, openAtStart.contains(app.processIdentifier) { return .hide }
        return action
    }

    /// What one sweep does to one running app.
    enum SweepStep: Sendable, Equatable {
        /// Hide it and ask it to quit again.
        case askToQuit
        /// Hide it (it is not hidden now).
        case hide
        case nothing
    }

    /// The sweep's decision for one app, pure so it can be tested without a
    /// real process. Follows `enforce` and `action(for:)` exactly: exempt apps
    /// and Nidus are never touched, allow mode only hides what was open at
    /// start, and a hidden app under `.hide` is left alone.
    nonisolated static func sweepStep(bundleID: String, isTerminated: Bool, isHidden: Bool,
                                      wasOpenAtStart: Bool, mode: Mode, action: Action) -> SweepStep {
        guard !isTerminated, isBlocked(bundleID, under: mode) else { return .nothing }
        var effective = action
        if case .allow = mode, wasOpenAtStart { effective = .hide }
        switch effective {
        case .terminate: return .askToQuit
        case .hide: return isHidden ? .nothing : .hide
        }
    }

    /// A low-frequency second look, driven by the controller's once-a-second
    /// tick (no timer of its own). `retryQuit` gives up after six seconds, so
    /// an app that refused to quit (an unsaved-changes alert, a modal sheet,
    /// one that ignores the Apple Event) would otherwise stay usable for the
    /// rest of the session. Every blocked regular app still running is hidden
    /// and asked again, politely, never forceTerminate(). It does not call
    /// `onBlock`: that reports a card and counts a block, and a sweep every few
    /// seconds would spam both. One `runningApplications` read per sweep.
    func sweep() {
        guard !observers.isEmpty else { return }
        var refused: [String: String] = [:]
        let now = Date()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier else { continue }
            let step = Self.sweepStep(bundleID: bundleID, isTerminated: app.isTerminated, isHidden: app.isHidden,
                                      wasOpenAtStart: openAtStart.contains(app.processIdentifier),
                                      mode: mode, action: action)
            switch step {
            case .nothing: break
            case .hide: app.hide()
            case .askToQuit:
                app.hide()
                app.terminate()
                if now.timeIntervalSince(app.launchDate ?? .distantPast) > Self.refusalGrace {
                    refused[bundleID] = app.localizedName ?? bundleID
                }
            }
        }
        if refused != refusedToQuit { refusedToQuit = refused }
    }

    private func retryQuit(_ app: NSRunningApplication, after delays: [TimeInterval]) {
        guard let delay = delays.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.observers.isEmpty, !app.isTerminated,
                      let bundleID = app.bundleIdentifier, self.isBlocked(bundleID),
                      self.action(for: app) == .terminate else { return }
                app.hide()
                app.terminate()
                self.retryQuit(app, after: Array(delays.dropFirst()).map { $0 - delay })
            }
        }
    }

    private func enforce(_ app: NSRunningApplication) {
        // Only apps with a Dock icon: agents, helpers and daemons are left alone.
        guard app.activationPolicy == .regular, !app.isTerminated,
              let bundleID = app.bundleIdentifier, isBlocked(bundleID) else { return }
        switch action(for: app) {
        case .terminate:
            app.terminate()
            // A polite quit can be missed: one sent while the app is still
            // launching, or swallowed by a modal panel (TextEdit's Open sheet,
            // an unsaved-changes alert). While it is still up and still
            // blocked, hide it and ask again, a few times. Never
            // forceTerminate(): that loses work.
            retryQuit(app, after: [1, 3, 6])
        case .hide:
            app.hide()
        }
        onBlock(app)
    }
}
