//
//  SettingsWindowController.swift
//  Nidus
//
//  The Settings window: one page, with links to the pages under it (Stats,
//  each category, Apps to open) and a Back button over those. A plain window
//  rather than SwiftUI's Settings scene, which an app that lives in the menu
//  bar can't reliably open.
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    let router = SettingsRouter()
    weak var model: NidusModel?
    private var window: NSWindow?

    func show(page: String? = nil, title: String = "") {
        guard let model else { return }
        if let page { router.reset(to: page, title: title) }
        let window = window ?? makeWindow(model: model)
        self.window = window
        NSApp.activate()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(model: NidusModel) -> NSWindow {
        let root = SettingsRoot(model: model, router: router)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Nidus"
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(NSSize(width: 640, height: 720))
        window.contentMinSize = NSSize(width: 560, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("Nidus Settings")
        return window
    }
}

struct SettingsRoot: View {
    @ObservedObject var model: NidusModel
    let router: SettingsRouter

    var body: some View {
        VStack(spacing: 0) {
            if let page = router.path.last {
                pageHeader(page)
                Rectangle().fill(Solanum.hairline).frame(height: 1)
                (model.makeSettingsPage(id: page.id) ?? AnyView(missing))
                    .id(page)
            } else {
                FocusSettingsPane(model: model)
                footer
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Solanum.page)
        .environment(router)
    }

    private func pageHeader(_ page: SettingsRouter.Page) -> some View {
        HStack(spacing: 10) {
            Button(action: router.back) {
                Label(router.path.count > 1 ? router.path[router.path.count - 2].title : "Settings",
                      systemImage: "chevron.left")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(SolanumButtonStyle())
            .keyboardShortcut("[", modifiers: .command)
            Text(page.title)
                .font(Solanum.serif(20))
                .foregroundStyle(Solanum.ink)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 12)
    }

    private var missing: some View {
        Text("This page is gone.")
            .foregroundStyle(Solanum.inkMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Nidus")
                .font(Solanum.serif(20))
                .foregroundStyle(Solanum.ink)
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                .font(.system(size: 11, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(Solanum.inkFaint)
            Spacer()
            Text("A Solanum product.")
                .font(.system(size: 12))
                .foregroundStyle(Solanum.inkMuted)
        }
        .padding(.horizontal, 32)
        .frame(height: 56)
        .overlay(alignment: .top) { Rectangle().fill(Solanum.hairline).frame(height: 1).padding(.horizontal, 32) }
    }
}
