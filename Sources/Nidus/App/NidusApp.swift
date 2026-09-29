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

        LoginItem.registerOnFirstLaunch()
        watchForTerminate()
        pendingURLs.forEach(model.handle)
        pendingURLs = []
        Demo.openRequestedSurfaces(model: model, settings: settings)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.deactivate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model else { return pendingURLs.append(contentsOf: urls) }
        urls.forEach(model.handle)
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
        FocusWidget(model: model, context: ShelfWidgetContext())
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
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
    }
}

// MARK: - Demo

/// `Nidus --demo <scenario> [--open popover|settings|stats]`: opens in a
/// state for screenshots, with a sample session that blocks nothing, its own
/// settings and a throwaway folder. Launch it with `open -n` beside a real
/// copy. Scenarios are NidusModel.harnessScenario's.
enum Demo {
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
}
