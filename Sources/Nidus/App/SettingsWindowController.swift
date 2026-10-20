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

    /// All current tabs have a page. Enumerating them must not construct
    /// each SwiftUI root (and its state) just to find that out.
    var tabs: [SettingsTab] {
        model == nil ? [] : SettingsTab.allCases
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
            let router = router(for: tab)
            controller.add(tab) {
                let hosting = NSHostingController(rootView: SettingsRoot(model: model, tab: tab, router: router))
                // The window keeps its size; each page scrolls inside it.
                hosting.sizingOptions = []
                return hosting
            }
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
        window.onFind = { [weak model] in model?.settingsJump.requestFocus() }
        window.onClose = { [weak self] in
            // Keep the lightweight routes, not the hosting graphs and charts.
            self?.model?.settingsJump.clearDestination()
            self?.tabController?.releasePages()
            self?.window?.contentViewController = nil
            self?.window = nil
            self?.tabController = nil
        }
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
    /// ⌘F: focus Jump to.
    var onFind: (() -> Void)?
    var onClose: (() -> Void)?

    override func close() {
        super.close()
        onClose?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "f", let onFind {
            onFind()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        placesAnywhere ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// The tabs along the toolbar, one page each. The window's title is the
/// tab's name, which the controller doesn't set on its own.
final class SettingsTabViewController: NSTabViewController {
    var onSelect: ((SettingsTab) -> Void)?
    private var isReady = false

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        tabStyle = .toolbar
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        tabStyle = .toolbar
    }

    func add(_ tab: SettingsTab, makePage: @escaping () -> NSViewController) {
        let page = LazySettingsTabController(makePage: makePage)
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
        isReady = true
        selectedTabViewItemIndex = index
        materialize(tabViewItems[index])
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let tabViewItem, let tab = Self.tab(of: tabViewItem) else { return }
        if isReady { materialize(tabViewItem) }
        view.window?.title = tab.title
        onSelect?(tab)
    }

    private static func tab(of item: NSTabViewItem) -> SettingsTab? {
        (item.identifier as? String).flatMap(SettingsTab.init(rawValue:))
    }

    private func materialize(_ item: NSTabViewItem) {
        (item.viewController as? LazySettingsTabController)?.materialize()
    }

    /// A closed NSWindow can outlive its controller in AppKit. Detach heavy
    /// content explicitly instead of relying on the window's deallocation.
    func releasePages() {
        isReady = false
        for item in tabViewItems {
            (item.viewController as? LazySettingsTabController)?.releasePage()
        }
    }
}

/// NSTabViewController may ask every item for a view while building its
/// toolbar. Those views are cheap placeholders; only selection creates the
/// SwiftUI host. Visited tabs retain UI state until the window closes.
final class LazySettingsTabController: NSViewController {
    private let makePage: () -> NSViewController
    private(set) var page: NSViewController?
    private var pageConstraints: [NSLayoutConstraint] = []

    init(makePage: @escaping () -> NSViewController) {
        self.makePage = makePage
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() { view = NSView() }

    func materialize() {
        guard page == nil else { return }
        let page = makePage()
        self.page = page
        addChild(page)
        page.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page.view)
        pageConstraints = [
            page.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            page.view.topAnchor.constraint(equalTo: view.topAnchor),
            page.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        NSLayoutConstraint.activate(pageConstraints)
    }

    func releasePage() {
        guard let page else { return }
        NSLayoutConstraint.deactivate(pageConstraints)
        pageConstraints.removeAll()
        page.view.removeFromSuperview()
        page.removeFromParent()
        self.page = nil
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
        let jump = model.settingsJump
        VStack(spacing: 0) {
            SettingsJumpBar(jump: jump)
            PersistenceWarningView(persistence: model.persistence)
            Divider()
            // What the query finds covers the page; the page stays under it.
            ZStack {
                VStack(spacing: 0) {
                    if let page = router.path.last {
                        pageHeader(page)
                        Divider()
                        (model.makeSettingsPage(id: page.id) ?? AnyView(missing))
                            .id(page)
                            .environment(\.settingsPageID, page.id)
                    } else {
                        (model.settingsRoot(for: tab) ?? AnyView(missing))
                            .environment(\.settingsPageID, tab.pageID)
                    }
                }
                .disabled(jump.isSearching)
                .allowsHitTesting(!jump.isSearching)
                .accessibilityHidden(jump.isSearching)
                if jump.isSearching { SettingsJumpResults(jump: jump) }
            }
        }
        .environment(router)
        .environment(\.settingsJump, jump)
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
