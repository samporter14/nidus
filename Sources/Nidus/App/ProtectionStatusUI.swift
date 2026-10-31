//
//  ProtectionStatusUI.swift
//  Nidus
//
//  The protection line (ProtectionStatus) as the popover and the menu show
//  it, and the card that offers to block a browser Nidus can't watch as an
//  app, once, when a session that blocks websites starts.
//

import AppKit
import SwiftUI

extension NidusModel {
    static let uncoveredBrowserHUDID = "focus.uncovered-browser"

    /// What the session covers right now. nil when nothing is being blocked.
    var protectionStatus: ProtectionStatus? {
        guard !Demo.isActive, let controller, let enforcement = engine?.enforcement else { return nil }
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        var status = ProtectionStatus()
        status.blocksWebsites = !(enforcement.mode == .block && enforcement.websites.isEmpty)
        for browser in BrowserProfile.known where runningIDs.contains(browser.bundleID) {
            switch controller.browserAccess[browser.bundleID] {
            case .notPermitted?, .needsConsent?: status.noPermission.append(browser.shortName)
            default: status.watched.append(browser.shortName)
            }
        }
        let names = Dictionary(running.compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } },
                               uniquingKeysWith: { first, _ in first })
        status.unwatched = UncoveredBrowsers.uncovered(Self.cachedWebLinkHandlers.filter(runningIDs.contains))
            .filter { !AppBlocker.isBlocked($0, under: enforcement.appMode) }
            .map { names[$0] ?? UncoveredBrowsers.named[$0] ?? $0 }
        status.refused = controller.refusedApps.values.sorted()
        return status
    }

    /// The handlers as of the session's start, so the popover, redrawn every
    /// second, doesn't ask Launch Services each time.
    @MainActor private static var handlerCache: [String]?
    static var cachedWebLinkHandlers: [String] {
        if let handlerCache { return handlerCache }
        let found = webLinkHandlers()
        handlerCache = found
        return found
    }

    /// Apps that open web links, as Launch Services knows them, and the
    /// named browsers that are installed.
    static func webLinkHandlers() -> [String] {
        let workspace = NSWorkspace.shared
        var page = URLComponents()
        page.scheme = "https"
        page.host = "example.com"
        var ids = workspace.urlsForApplications(toOpen: page.url!)
            .compactMap { Bundle(url: $0)?.bundleIdentifier }
        ids += UncoveredBrowsers.named.keys.sorted().filter { workspace.urlForApplication(withBundleIdentifier: $0) != nil }
        return ids
    }

    /// At the start of a session that blocks websites: browsers Nidus can't
    /// watch that are open or installed, and not blocked as apps already,
    /// get one card offering to block them as apps for this session.
    func offerToBlockUncoveredBrowsers() {
        guard !Demo.isActive, let host, let enforcement = engine?.enforcement,
              !(enforcement.mode == .block && enforcement.websites.isEmpty) else { return }
        let handlers = Self.webLinkHandlers()
        Self.handlerCache = handlers
        let ids = UncoveredBrowsers.toOffer(UncoveredBrowsers.uncovered(handlers),
                                            blockedAsApp: { AppBlocker.isBlocked($0, under: enforcement.appMode) })
        guard !ids.isEmpty else { return }
        let names = ids.map(Self.appName)
        let list = ProtectionStatus.list(names)
        let title = "Can\u{2019}t block sites in \(list)"
        let detail = names.count == 1 ? "Block it as an app until this session ends?" : "Block them as apps until this session ends?"
        let request = HUDRequest(
            id: Self.uncoveredBrowserHUDID,
            duration: 15,
            accessibilityLabel: "\(title). \(detail)"
        ) { [weak self] in
            FocusNoticeCard(symbol: "globe", variants: [
                .init(title: Text(verbatim: title), detail: Text(verbatim: detail), button: "Block"),
                .init(title: Text(verbatim: title), detail: Text("For this session"), button: "Block"),
            ]) {
                self?.engine?.blockAppsForSession(ids)
                self?.host?.hud.dismiss(id: Self.uncoveredBrowserHUDID)
            }
        }
        host.hud.present(request)
    }

    private static func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return UncoveredBrowsers.named[bundleID] ?? bundleID
    }
}

extension Enforcement {
    /// The app blocker's mode for these rules.
    var appMode: AppBlocker.Mode { mode == .block ? .block(apps) : .allow(apps) }
}

/// The popover's protection line, under the countdown.
struct ProtectionStatusLine: View {
    let status: ProtectionStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: status.isComplete ? "checkmark.shield" : "exclamationmark.shield")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(status.isComplete ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Solanum.clayText))
                .accessibilityHidden(true)
            Text(verbatim: status.line)
                .font(.system(size: 12))
                .foregroundStyle(status.isComplete ? AnyShapeStyle(.secondary) : AnyShapeStyle(Solanum.ink))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Protection: \(status.line)")
    }
}
