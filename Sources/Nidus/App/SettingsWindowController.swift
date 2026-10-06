//
//  SettingsWindowController.swift
//  Nidus
//
//  The Settings window: toolbar tabs, as a Mac app's Settings has them
//  (SettingsTabs.swift lists them). Each tab is its own SwiftUI page with its
//  own stack of pages pushed on it, and a Back button over those. A plain
//  window rather than SwiftUI's Settings scene, which an app that lives in
//  the menu bar can't reliably open.
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    weak var model: NidusModel?
    private(set) var window: SettingsWindow?
    /// The tab showing, or the one to show when the window is next made.
    private(set) var selectedTab: SettingsTab = .general
    private var tabController: SettingsTabViewController?
    /// One stack of pages per tab. They outlive the window, so a closed
    /// Settings reopens where it was.
    private var routers: [SettingsTab: SettingsRouter] = [:]

    static let contentSize = NSSize(width: 640, height: 600)
    static let frameAutosaveName = "Nidus Settings"

    func router(for tab: SettingsTab) -> SettingsRouter {
        if let router = routers[tab] { return router }
        let router = SettingsRouter()
        routers[tab] = router
        return router
    }

    /// The tabs the window has: every one whose page exists.
    var tabs: [SettingsTab] {
        guard let model else { return [] }
        return SettingsTab.available { model.settingsRoot(for: $0) != nil }
    }

    /// Opens Settings: on `page`, in the tab that page belongs to, or with
    /// no page, on the tab it was last left on.
    func show(page: String? = nil, title: String = "") {
        guard let model else { return }
        let window = window ?? makeWindow(model: model)
        self.window = window
        if let page { open(page, title: title) }
        if CaptureSurfaces.isActive { return window.orderFrontRegardless() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Back, over whatever is pushed on the tab showing. Pages call it when
    /// they delete themselves.
    func goBack() {
        router(for: selectedTab).back()
    }

    /// Selects the page's tab and puts the page there: on top of the tab's own
    /// page if it is one pushed inside it, or as that page itself, which
    /// clears what was pushed.
    private func open(_ page: String, title: String) {
        let route = SettingsRoute.resolve(page, available: Set(tabs))
        router(for: route.tab).reset(to: route.pushes ? page : nil, title: title)
        select(route.tab)
    }

    private func select(_ tab: SettingsTab) {
        selectedTab = tab
        tabController?.select(tab)
    }

    private func makeWindow(model: NidusModel, remembersFrame: Bool = true) -> SettingsWindow {
        // The tab the window was left on, read before the controller is
        // made: making it selects the first, and that would be remembered.
        let saved: String = model.preference(NidusModel.Key.settingsTab, default: "")
        let controller = SettingsTabViewController()
        for tab in tabs {
            let hosting = NSHostingController(rootView: SettingsRoot(model: model, tab: tab, router: router(for: tab)))
            // The window keeps the size it is given; each page scrolls inside it.
            hosting.sizingOptions = []
            controller.add(tab, hosting)
        }
        controller.select(SettingsTab.restored(from: saved, available: tabs))
        selectedTab = controller.selectedTab ?? .general
        controller.onSelect = { [weak self] tab in self?.didSelect(tab) }
        tabController = controller

        let window = SettingsWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                    backing: .buffered, defer: false)
        // Icons over their names in the middle of the title bar, as System
        // Settings had them, and a title that follows the tab.
        window.toolbarStyle = .preference
        window.contentViewController = controller
        window.title = selectedTab.title
        window.setContentSize(Self.contentSize)
        window.contentMinSize = NSSize(width: 560, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        if remembersFrame {
            // Where it was left, or the middle of the screen the first time.
            if !window.setFrameUsingName(Self.frameAutosaveName) { window.center() }
            window.setFrameAutosaveName(Self.frameAutosaveName)
        }
        return window
    }

    private func didSelect(_ tab: SettingsTab) {
        selectedTab = tab
        model?.host?.preferences.setValueQuietly(tab.rawValue, forKey: NidusModel.Key.settingsTab)
    }

    /// Render only: the window as the app builds it, ordered in where no
    /// screen is, so its toolbar and title can be drawn. It takes no focus
    /// and saves no frame.
    func showOffscreen(page: String, title: String = "") -> SettingsWindow? {
        guard let model else { return nil }
        let window = window ?? makeWindow(model: model, remembersFrame: false)
        self.window = window
        window.placesAnywhere = true
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        open(page, title: title)
        window.orderFrontRegardless()
        return window
    }
}

/// Settings' window. A render can place it where no screen is; the system
/// otherwise pulls a titled window back onto one.
final class SettingsWindow: NSWindow {
    var placesAnywhere = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        placesAnywhere ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// The tabs along the toolbar, one page each. The window's title is the
/// tab's name, which the controller doesn't set on its own.
final class SettingsTabViewController: NSTabViewController {
    var onSelect: ((SettingsTab) -> Void)?

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        tabStyle = .toolbar
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        tabStyle = .toolbar
    }

    func add(_ tab: SettingsTab, _ page: NSViewController) {
        page.title = tab.title
        let item = NSTabViewItem(viewController: page)
        item.identifier = tab.rawValue
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        addTabViewItem(item)
    }

    var selectedTab: SettingsTab? {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex) else { return nil }
        return Self.tab(of: tabViewItems[selectedTabViewItemIndex])
    }

    func select(_ tab: SettingsTab) {
        guard let index = tabViewItems.firstIndex(where: { Self.tab(of: $0) == tab }) else { return }
        selectedTabViewItemIndex = index
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let tabViewItem, let tab = Self.tab(of: tabViewItem) else { return }
        view.window?.title = tab.title
        onSelect?(tab)
    }

    private static func tab(of item: NSTabViewItem) -> SettingsTab? {
        (item.identifier as? String).flatMap(SettingsTab.init(rawValue:))
    }
}

/// One tab: its own page, or the page pushed on it with Back over it. Each
/// tab has a router of its own, which the links inside read from the
/// environment.
struct SettingsRoot: View {
    @ObservedObject var model: NidusModel
    let tab: SettingsTab
    let router: SettingsRouter

    var body: some View {
        VStack(spacing: 0) {
            if let page = router.path.last {
                pageHeader(page)
                Divider()
                (model.makeSettingsPage(id: page.id) ?? AnyView(missing))
                    .id(page)
            } else {
                (model.settingsRoot(for: tab) ?? AnyView(missing))
            }
        }
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
            .help("Back to \(router.path.count > 1 ? router.path[router.path.count - 2].title : tab.title)")
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
