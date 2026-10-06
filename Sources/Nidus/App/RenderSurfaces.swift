//
//  RenderSurfaces.swift
//  Nidus
//
//  `Nidus --render-surfaces <dir>`: draws the popover in each state, every
//  card and the Settings pages to PNGs, in Ivory and Slate, then quits. The
//  windows sit off-screen and Nidus never becomes the active app, so nothing
//  takes the keyboard from whatever you are typing in. Its session blocks
//  nothing, and it keeps its settings and files apart from yours (see Demo).
//

import AppKit
import SwiftUI

@MainActor
enum RenderSurfaces {
    private static let arguments = ProcessInfo.processInfo.arguments

    static var directory: URL? {
        guard let index = arguments.firstIndex(of: "--render-surfaces"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    nonisolated static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("--render-surfaces") }

    static func run() {
        guard let directory else { return NSApp.terminate(nil) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = SettingsWindowController()
        let host = NidusHost(settings: settings)
        let model = NidusModel()
        model.harnessScenario = "idle"
        settings.model = model
        model.activate(host: host)

        Task { @MainActor in
            // The popover, in each state.
            for scenario in ["idle", "running", "paused", "strict", "open-ended", "break"] {
                model.runHarnessScenario(scenario)
                if scenario == "idle" { model.goalDraft = "" }
                await shoot(NidusPopover(model: model), width: 440, name: "popover-\(scenario)", in: directory)
            }
            // The cards.
            for scenario in ["blocked", "finish", "wrapup", "browser", "snooze", "welcome", "strict-card"] {
                if scenario == "strict-card" {
                    model.presentStrictHUD()
                } else {
                    model.runHarnessScenario(scenario)
                }
                guard let request = host.hud.lastRequest else { continue }
                await shoot(HUDCardView(content: request.content), width: HUDPresenter.width,
                            name: "card-\(scenario)", in: directory, padded: true)
            }
            // The snooze pause (its three moments, then the block page's link
            // as the app takes it), and the finish card as it reads after an
            // answer or beside a break.
            for scenario in ["snooze-wait-start", "snooze-wait-mid", "snooze-wait-ready", "snooze-link",
                             "finish-yes", "finish-notyet", "finish-break", "finish-break-yes", "wrapup-break"] {
                model.runHarnessScenario(scenario)
                guard let request = host.hud.lastRequest else { continue }
                await shoot(HUDCardView(content: request.content), width: HUDPresenter.width,
                            name: "card-\(scenario)", in: directory, padded: true)
            }
            // Settings.
            model.runHarnessScenario("idle")
            model.snoozeWaitSeconds = 10
            await shoot(SettingsRoot(model: model, router: settings.router), width: 640, height: 900,
                        name: "settings-snooze-wait", in: directory)
            model.snoozeWaitSeconds = 0
            for (page, title) in [(nil, ""), ("stats", "Stats"), ("launch-apps", "Apps to open"),
                                  ("category:\(model.categories.first?.id ?? "")", model.categories.first?.name ?? "")] as [(String?, String)] {
                settings.router.reset(to: page, title: title)
                let name = "settings-" + (page.map { $0.hasPrefix("category:") ? "category" : $0 } ?? "main")
                await shoot(SettingsRoot(model: model, router: settings.router), width: 640, height: 900, name: name, in: directory)
            }
            await renderStatsExtras(model: model, settings: settings, host: host, in: directory)
            // After Settings, so the Stats page above is drawn without them.
            await shootPopoverVariants(model: model, settings: settings, in: directory)
            await renderSetups(model: model, settings: settings, in: directory)
            await renderSchedules(model: model, settings: settings, host: host, in: directory)
            model.deactivate()
            NSApp.terminate(nil)
        }
    }

    /// The popover's states beyond the six above: the running line, the idle
    /// footer, the custom length. Every session here blocks nothing; a
    /// blocked count is set on the session's own state, as the finish card's
    /// is. Settings it changes are the demo's own, and are put back.
    private static func shootPopoverVariants(model: NidusModel, settings: SettingsWindowController, in directory: URL) async {
        guard let controller = model.controller else { return }
        let popover = NidusPopover(model: model)

        func blocked(_ times: Int) {
            for _ in 0..<times { controller.engine.recordBlock("youtube.com", name: "youtube.com") }
        }
        func start(goal: String, minutes: Double?) {
            controller.start(SessionPlan(goal: goal, duration: minutes.map { $0 * 60 }, mode: .block, apps: [], websites: []))
        }

        // Running: a goal and two blocks, one block, no goal, a long goal.
        model.runHarnessScenario("running")
        blocked(2)
        await shoot(popover, width: 440, name: "popover-running-blocks", in: directory)
        model.runHarnessScenario("running")
        blocked(1)
        await shoot(popover, width: 440, name: "popover-running-blocked-once", in: directory)
        start(goal: "", minutes: 25)
        blocked(2)
        await shoot(popover, width: 440, name: "popover-running-nogoal", in: directory)
        start(goal: "Finish the methods section and rerun every figure for the revision", minutes: 90)
        blocked(14)
        await shoot(popover, width: 440, name: "popover-running-longgoal", in: directory)
        model.runHarnessScenario("open-ended")
        blocked(2)
        await shoot(popover, width: 440, name: "popover-open-ended-blocks", in: directory)
        model.runHarnessScenario("paused")
        blocked(2)
        await shoot(popover, width: 440, name: "popover-paused-blocks", in: directory)

        // Idle, with the history it reads.
        model.runHarnessScenario("idle")
        model.goalDraft = ""
        func entry(daysAgo: Int, minutes: Double, minuteOfDay: Int) -> SessionEntry {
            let calendar = Calendar.current
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date()))!
            let start = day.addingTimeInterval(TimeInterval(minuteOfDay * 60))
            return SessionEntry(start: start, end: start.addingTimeInterval(minutes * 60), focused: minutes * 60,
                                planned: minutes * 60, outcome: .completed)
        }
        for sample in [entry(daysAgo: 2, minutes: 25, minuteOfDay: 600), entry(daysAgo: 1, minutes: 45, minuteOfDay: 600),
                       entry(daysAgo: 0, minutes: 45, minuteOfDay: 10), entry(daysAgo: 0, minutes: 25, minuteOfDay: 20)] {
            controller.history.append(sample)
        }
        await shoot(popover, width: 440, name: "popover-idle-footer", in: directory)
        model.recordsHistory = false
        await shoot(popover, width: 440, name: "popover-idle-history-off", in: directory)
        model.recordsHistory = true
        controller.clearHistory()
        // A streak waiting, nothing focused yet today.
        for sample in [entry(daysAgo: 3, minutes: 25, minuteOfDay: 600), entry(daysAgo: 2, minutes: 25, minuteOfDay: 600),
                       entry(daysAgo: 1, minutes: 45, minuteOfDay: 600)] {
            controller.history.append(sample)
        }
        await shoot(popover, width: 440, name: "popover-idle-streak-waiting", in: directory)
        controller.clearHistory()

        // The custom length field: open, typed, and not understood.
        model.openCustomLength()
        await shoot(popover, width: 440, name: "popover-idle-custom", in: directory)
        model.customLengthDraft?.text = "1h30"
        await shoot(popover, width: 440, name: "popover-idle-custom-hours", in: directory)
        model.customLengthDraft?.text = "until 3:30pm"
        await shoot(popover, width: 440, name: "popover-idle-custom-until", in: directory)
        model.customLengthDraft?.text = "banana"
        model.commitCustomLength()
        await shoot(popover, width: 440, name: "popover-idle-custom-error", in: directory)
        model.cancelCustomLength()

        // An "until" time chosen, with a block list and with an allow list
        // (whose button is wider), and a saved length of 40 minutes.
        model.untilTarget = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 15, minute: 30),
                                                      matchingPolicy: .nextTime)
        await shoot(popover, width: 440, name: "popover-idle-until", in: directory)
        model.mode = .allow
        await shoot(popover, width: 440, name: "popover-idle-until-allow", in: directory)
        model.untilTarget = nil
        model.durationMinutes = 40
        await shoot(popover, width: 440, name: "popover-idle-custom-minutes", in: directory)
        model.openCustomLength()
        model.customLengthDraft?.text = "1h30"
        await shoot(popover, width: 440, name: "popover-idle-custom-allow", in: directory)
        model.cancelCustomLength()
        model.mode = .block

        // Settings' Session length with that 40 in it.
        settings.router.reset(to: nil, title: "")
        await shoot(SettingsRoot(model: model, router: settings.router), width: 640, height: 900,
                    name: "settings-main-custom-length", in: directory)
        model.durationMinutes = 25
    }

    static func shoot<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, name: String,
                               in directory: URL, padded: Bool = false) async {
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let root = view
                .padding(padded ? 24 : 0)
                .background(padded ? Color(nsColor: .windowBackgroundColor) : .clear)
            let hosting = NSHostingView(rootView: root)
            hosting.appearance = NSAppearance(named: appearance)
            let pad: CGFloat = padded ? 48 : 0
            let size: NSSize
            if let height {
                size = NSSize(width: width + pad, height: height + pad)
            } else {
                hosting.frame = NSRect(x: 0, y: 0, width: width + pad, height: 10)
                let fit = hosting.fittingSize
                size = NSSize(width: width + pad, height: fit.height)
            }
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = hosting.appearance
            window.contentView = hosting
            window.orderFrontRegardless()
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(350))
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("\(name)-\(theme).png"))
            window.orderOut(nil)
        }
    }
}

/// `Nidus --capture-surfaces <dir>`: shows the real popover, cards and
/// Settings window one at a time, in each theme, and for each prints
/// `CAPTURE <name> <window number>`, then waits for `<dir>/<name>.done`. A
/// script beside it runs `screencapture -l` on the window (materials and
/// Liquid Glass draw only on screen), then touches the file. Nidus never
/// becomes the active app, so the keyboard stays where it was.
@MainActor
enum CaptureSurfaces {
    nonisolated static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("--capture-surfaces") }

    static func run() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--capture-surfaces"), index + 1 < arguments.count else {
            return NSApp.terminate(nil)
        }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = SettingsWindowController()
        let host = NidusHost(settings: settings)
        let model = NidusModel()
        model.harnessScenario = "idle"
        settings.model = model
        model.activate(host: host)

        Task { @MainActor in
            // The first popover takes a moment to make its window.
            model.showPopover()
            try? await Task.sleep(for: .milliseconds(800))
            model.menuBarItem?.closePopover()
            try? await Task.sleep(for: .milliseconds(300))
            for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                for scenario in ["idle", "running", "break"] {
                    model.runHarnessScenario(scenario)
                    if scenario == "idle" { model.goalDraft = "" }
                    model.showPopover()
                    try? await Task.sleep(for: .milliseconds(700))
                    await capture("popover-\(scenario)-\(theme)", model.menuBarItem?.popoverWindowNumber, in: directory)
                    model.menuBarItem?.closePopover()
                    try? await Task.sleep(for: .milliseconds(300))
                }
                for scenario in ["blocked", "finish", "browser"] {
                    model.runHarnessScenario(scenario)
                    try? await Task.sleep(for: .milliseconds(700))
                    await capture("card-\(scenario)-\(theme)", host.hud.windowNumber, in: directory)
                }
                model.runHarnessScenario("idle")
                for (page, title) in [(nil, ""), ("stats", "Stats")] as [(String?, String)] {
                    settings.router.reset(to: page, title: title)
                    settings.show()
                    try? await Task.sleep(for: .milliseconds(700))
                    await capture("settings-\(page ?? "main")-\(theme)", settings.window?.windowNumber, in: directory)
                }
                settings.window?.orderOut(nil)
            }
            model.deactivate()
            NSApp.terminate(nil)
        }
    }

    private static func capture(_ name: String, _ window: Int?, in directory: URL) async {
        guard let window else { return print("MISSING \(name)") }
        let done = directory.appendingPathComponent("\(name).done")
        print("CAPTURE \(name) \(window)")
        fflush(stdout)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: done.path) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
