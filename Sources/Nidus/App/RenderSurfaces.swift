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
            // Settings.
            model.runHarnessScenario("idle")
            for (page, title) in [(nil, ""), ("stats", "Stats"), ("launch-apps", "Apps to open"),
                                  ("category:\(model.categories.first?.id ?? "")", model.categories.first?.name ?? "")] as [(String?, String)] {
                settings.router.reset(to: page, title: title)
                let name = "settings-" + (page.map { $0.hasPrefix("category:") ? "category" : $0 } ?? "main")
                await shoot(SettingsRoot(model: model, router: settings.router), width: 640, height: 900, name: name, in: directory)
            }
            model.deactivate()
            NSApp.terminate(nil)
        }
    }

    private static func shoot<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, name: String,
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
