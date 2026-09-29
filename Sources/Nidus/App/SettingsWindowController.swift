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
    private(set) var window: NSWindow?

    func show(page: String? = nil, title: String = "") {
        guard let model else { return }
        if let page { router.reset(to: page, title: title) }
        let window = window ?? makeWindow(model: model)
        self.window = window
        if !window.isVisible { window.center() }
        if CaptureSurfaces.isActive { return window.orderFrontRegardless() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(model: NidusModel) -> NSWindow {
        let root = SettingsRoot(model: model, router: router)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Nidus"
        let hosting = NSHostingController(rootView: root)
        // The window keeps the size it is given; the page scrolls inside it.
        hosting.sizingOptions = []
        window.contentViewController = hosting
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
                Divider()
                (model.makeSettingsPage(id: page.id) ?? AnyView(missing))
                    .id(page)
            } else {
                FocusSettingsPane(model: model)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .environment(router)
    }

    /// Back and the page's title, where System Settings puts them.
    private func pageHeader(_ page: SettingsRouter.Page) -> some View {
        HStack(spacing: 8) {
            Button(action: router.back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back to \(router.path.count > 1 ? router.path[router.path.count - 2].title : "Settings")")
            .accessibilityLabel("Back")
            Text(page.title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var missing: some View {
        Text("This page is gone.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
