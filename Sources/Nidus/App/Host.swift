//
//  Host.swift
//  Nidus
//
//  What the model asks of the app around it: settings, a folder of its own,
//  the cards at the top of the screen, a click of feedback, and the Settings
//  window. One of each, made by the app delegate.
//

import AppKit
import Combine
import OSLog

@MainActor
final class NidusHost {
    let preferences = Preferences()
    let environment = Environment()
    let hud = HUDPresenter()
    let feedback = Feedback()
    let workspace: Workspace
    let log = Logger(subsystem: "local.sam.nidus", category: "app")

    init(settings: SettingsWindowController) {
        workspace = Workspace(settings: settings)
    }

    /// Everything the model may ask to use; an app has it all.
    func isGranted(_ capability: Capability) -> Bool { true }

    enum Capability { case menuBar }

    // MARK: Settings

    /// Settings in the app's own defaults, each value JSON-coded so any
    /// Codable fits.
    @MainActor
    final class Preferences {
        let didChange = PassthroughSubject<String, Never>()
        /// The demo keeps its own, emptied at each launch, so it never
        /// touches yours.
        private let defaults: UserDefaults = {
            guard Demo.isActive, let demo = UserDefaults(suiteName: "local.sam.nidus.demo") else { return .standard }
            demo.removePersistentDomain(forName: "local.sam.nidus.demo")
            return demo
        }()

        func value<Value: Codable>(forKey key: String, default value: Value) -> Value {
            guard let data = defaults.data(forKey: key),
                  let decoded = try? JSONDecoder().decode(Value.self, from: data) else { return value }
            return decoded
        }

        func setValue<Value: Codable>(_ value: Value, forKey key: String) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            defaults.set(data, forKey: key)
            didChange.send(key)
        }
    }

    struct Environment {
        /// ~/Library/Application Support/Nidus: the session, the history and
        /// the block page.
        let containerDirectory: URL = {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // The demo's session and history go in a throwaway folder.
            let url = Demo.isActive
                ? FileManager.default.temporaryDirectory.appendingPathComponent("nidus-demo-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
                : base.appendingPathComponent("Nidus", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }()

        /// Droppy's test harness; the app has none. Its demo mode is `Demo`.
        let isHarness = false
    }

    /// A tap on the trackpad, where there is one. No sound.
    struct Feedback {
        enum Kind { case success, tick, failure }

        func play(_ kind: Kind) {
            let pattern: NSHapticFeedbackManager.FeedbackPattern = kind == .tick ? .alignment : .levelChange
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
    }

    @MainActor
    struct Workspace {
        let settings: SettingsWindowController

        @discardableResult
        func openSettings() -> Bool {
            settings.show()
            return true
        }

        @discardableResult
        func openSettingsPage(_ id: String, title: String) -> Bool {
            settings.show(page: id, title: title)
            return true
        }

        @discardableResult
        func goBackInSettings() -> Bool {
            settings.router.back()
            return true
        }

        @discardableResult
        func openShortcuts() -> Bool {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") else { return false }
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            return true
        }
    }
}
