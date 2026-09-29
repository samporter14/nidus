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

    /// Never blocked, whatever the mode. The host is added at runtime: in
    /// Nidus's process, `Bundle.main` is Nidus. Droppy stays exempt too.
    static let exempt: Set<String> = [
        "iordv.Droppy",
        "iordv.DroppyPlayground",
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

    init(mode: Mode, action: Action, onBlock: @escaping (NSRunningApplication) -> Void = { _ in }) {
        self.mode = mode
        self.action = action
        self.onBlock = onBlock
    }

    func isBlocked(_ bundleID: String) -> Bool {
        if Self.exempt.contains(bundleID) || bundleID == Bundle.main.bundleIdentifier { return false }
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
    }

    /// What to do with this app: the chosen action, except that allow mode
    /// only hides what was already open.
    func action(for app: NSRunningApplication) -> Action {
        if case .allow = mode, openAtStart.contains(app.processIdentifier) { return .hide }
        return action
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
