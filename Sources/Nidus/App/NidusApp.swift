//
//  NidusApp.swift
//  Nidus
//
//  Launch: one Nidus at a time, living in the menu bar (no Dock icon, no
//  main window). The app delegate makes the host and the model, answers
//  nidus:// links, and opens at login.
//

import AppKit
import OSLog
import ServiceManagement
import SwiftUI

@main
enum NidusMain {
    static func main() {
        #if !DEBUG
        let developmentFlags: Set<String> = ["--demo", "--render-surfaces", "--render-brick-surfaces",
                                             "--render-activity-surfaces", "--capture-surfaces"]
        if ProcessInfo.processInfo.arguments.contains(where: developmentFlags.contains) {
            FileHandle.standardError.write(Data("Demo and render modes require a debug build of Nidus.\n".utf8))
            return
        }
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: SettingsWindowController?
    private var host: NidusHost?
    private(set) var model: NidusModel?
    private var sigterm: DispatchSourceSignal?
    /// Links that arrived before the model was ready.
    private var pendingURLs: [URL] = []
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !Demo.isActive, handOffToRunningCopy() { return }
        if RenderSurfaces.isActive { return RenderSurfaces.run() }
        if CaptureSurfaces.isActive { return CaptureSurfaces.run() }

        let settings = SettingsWindowController()
        let host = NidusHost(settings: settings)
        let model = NidusModel()
        model.harnessScenario = Demo.scenario
        settings.model = model
        model.activate(host: host)
        self.settings = settings
        self.host = host
        self.model = model
        // Shortcuts actions (FocusIntents.swift) reach the app through this.
        if !Demo.isActive { NidusModel.running = model }
        connectBrickFileIfRequested(model: model, host: host)

        LoginItem.registerOnFirstLaunch()
        watchForTerminate()
        pendingURLs.forEach(model.handle)
        pendingURLs = []
        Demo.openRequestedSurfaces(model: model, settings: settings)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Demo.isActive, let model, let controller = model.controller else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        controller.prepareForTermination { [weak self, model] in
            Task { @MainActor in
                var durable = await model.persistence.flush()
                // A note or inbox edit can arrive while the writer's idle
                // callback is returning to the main actor. Recheck its current
                // state before approving quit, without yielding after the check.
                while durable && !model.persistence.isDurable {
                    durable = await model.persistence.flush()
                }
                guard let self else { return }
                if !durable {
                    controller.resumeAfterCancelledTermination()
                    model.host?.log.error("Quit cancelled because local changes could not be saved")
                }
                if durable, controller.shutdownRestorationIncomplete {
                    model.host?.log.warning("Some browser tabs could not be restored within the quit deadline")
                }
                self.terminationPending = false
                NSApp.reply(toApplicationShouldTerminate: durable)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.deactivate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model else { return pendingURLs.append(contentsOf: urls) }
        urls.forEach(model.handle)
    }

    /// One-time local setup for a file created by Shortcuts. Make and test the
    /// security-scoped bookmark in Nidus itself before changing its preference.
    private func connectBrickFileIfRequested(model: NidusModel, host: NidusHost) {
        let arguments = ProcessInfo.processInfo.arguments
        let flags = arguments.indices.filter { arguments[$0] == "--connect-brick-file" }
        guard !flags.isEmpty else { return }

        func report(_ message: String, success: Bool = false) {
            let line = "Nidus brick file connection \(success ? "succeeded" : "failed"): \(message)\n"
            FileHandle.standardOutput.write(Data(line.utf8))
            if !success { host.log.error("Brick file connection failed: \(message, privacy: .public)") }
        }

        guard !Demo.isActive else { report("unavailable in demo mode"); return }
        guard flags.count == 1, flags[0] + 1 < arguments.count,
              arguments[flags[0] + 1].hasPrefix("/") else {
            report("expected one absolute file path after --connect-brick-file")
            return
        }
        let url = URL(fileURLWithPath: arguments[flags[0] + 1]).standardizedFileURL
        guard let initial = BrickFileReader.readFile(at: url).data,
              let signal = BrickSignal.parse(initial), signal.hasValidStructure else {
            report("file must be a readable regular JSON request of at most 4 KB")
            return
        }
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil, relativeTo: nil),
              let verified = BrickFileReader.read(bookmark: bookmark).data,
              let verifiedSignal = BrickSignal.parse(verified), verifiedSignal.hasValidStructure else {
            report("Nidus could not create and read its own file bookmark")
            return
        }
        model.brickFileBookmark = bookmark
        model.brickEnabled = true
        _ = UserDefaults.standard.synchronize()
        report("bookmark verified and companion enabled", success: true)
    }

    /// Opening Nidus again, from Finder or Spotlight, opens its popover.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.showPopover()
        return false
    }

    /// Another copy is running (an older one, say, from elsewhere): leave it
    /// in charge, since two would block twice.
    private func handOffToRunningCopy() -> Bool {
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me.processIdentifier }
        guard !others.isEmpty else { return false }
        Logger(subsystem: "local.sam.nidus", category: "app").info("Another Nidus is running; quitting this one")
        NSApp.terminate(nil)
        return true
    }

    /// `kill` or an update's installer: quit as ⌘Q does, so the session is
    /// saved and the menu bar item goes.
    private func watchForTerminate() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigterm = source
    }
}

extension NidusModel {
    func showPopover() { menuBarItem?.showPopover() }
}

/// The popover under the menu bar item.
struct NidusPopover: View {
    @ObservedObject var model: NidusModel

    var body: some View {
        FocusWidget(model: model)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 20)
            .frame(width: 440)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Open at login

enum LoginItem {
    private static let key = "loginItemOffered"

    /// Once: a blocker that isn't running blocks nothing. Settings can turn
    /// it off, and macOS shows it under Login Items.
    static func registerOnFirstLaunch() {
        guard !Demo.isActive, !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            // A failed registration can be retried on a later launch.
            // Approval pending is an actual registration, exposed in Settings.
            let status = SMAppService.mainApp.status
            if status == .enabled || status == .requiresApproval {
                UserDefaults.standard.set(true, forKey: key)
            }
        } catch {
            Logger(subsystem: "local.sam.nidus", category: "app").error("Open at login could not be registered: \(error.localizedDescription, privacy: .public)")
        }
    }

    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if on, SMAppService.mainApp.status == .requiresApproval {
                return "Allow Nidus in System Settings › General › Login Items."
            }
            guard isOn == on else { return "macOS has not applied this change. Try again in Login Items." }
            UserDefaults.standard.set(true, forKey: key)
            return nil
        } catch {
            return "Couldn’t change Open at login. \(error.localizedDescription)"
        }
    }
}

// MARK: - Demo

/// `Nidus --demo <scenario> [--open popover|settings|stats]`: opens in a
/// state for screenshots, with a sample session that blocks nothing, its own
/// settings and a throwaway folder. Launch it with `open -n` beside a real
/// copy. Scenarios are NidusModel.harnessScenario's.
enum Demo {
    #if DEBUG
    private static let arguments = ProcessInfo.processInfo.arguments

    private static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static let scenario = value(after: "--demo")
    static var isActive: Bool { scenario != nil || RenderSurfaces.isActive || CaptureSurfaces.isActive }

    @MainActor
    static func openRequestedSurfaces(model: NidusModel, settings: SettingsWindowController) {
        guard isActive, let what = value(after: "--open") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.8))
            switch what {
            case "popover": model.showPopover()
            case "settings": settings.show()
            case "stats": settings.show(page: "stats", title: "Stats")
            default: settings.show(page: what, title: what)
            }
        }
    }
    #else
    static let scenario: String? = nil
    static let isActive = false
    @MainActor static func openRequestedSurfaces(model: NidusModel, settings: SettingsWindowController) {}
    #endif
}
