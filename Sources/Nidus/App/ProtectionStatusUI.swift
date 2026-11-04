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
import UniformTypeIdentifiers

extension NidusModel {
    static let uncoveredBrowserHUDID = "focus.uncovered-browser"

    /// What the session covers right now. nil when nothing is being blocked.
    var protectionStatus: ProtectionStatus? {
        guard !Demo.isActive, let controller, let enforcement = engine?.enforcement else { return nil }
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        var status = ProtectionStatus()
        status.blocksWebsites = !(enforcement.mode == .block && enforcement.websites.isEmpty)
        for browser in BrowserProfile.known where status.blocksWebsites && runningIDs.contains(browser.bundleID)
            && !AppBlocker.isBlocked(browser.bundleID, under: enforcement.appMode) {
            switch controller.browserAccess[browser.bundleID] {
            case .notPermitted?, .needsConsent?: status.noPermission.append(browser.shortName)
            default: status.watched.append(browser.shortName)
            }
        }
        let names = Dictionary(running.compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } },
                               uniquingKeysWith: { first, _ in first })
        if status.blocksWebsites {
            status.unwatched = UncoveredBrowsers.runningToOffer(Self.cachedWebLinkHandlers, running: runningIDs,
                                                                blockedAsApp: { AppBlocker.isBlocked($0, under: enforcement.appMode) })
                .map { names[$0] ?? UncoveredBrowsers.named[$0] ?? $0 }
        }
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

    static func refreshWebLinkHandlers() { handlerCache = webLinkHandlers() }

    /// Browsers as Launch Services knows them: apps that open both web links
    /// and HTML files (a link alone also brings in chat apps and the like),
    /// and the named browsers that are installed.
    static func webLinkHandlers() -> [String] {
        let workspace = NSWorkspace.shared
        var page = URLComponents()
        page.scheme = "https"
        page.host = "example.com"
        let html = Set(workspace.urlsForApplications(toOpen: .html).compactMap { Bundle(url: $0)?.bundleIdentifier })
        var ids = workspace.urlsForApplications(toOpen: page.url!)
            .compactMap { Bundle(url: $0)?.bundleIdentifier }
            .filter(html.contains)
        ids += UncoveredBrowsers.named.keys.sorted().filter { workspace.urlForApplication(withBundleIdentifier: $0) != nil }
        return ids
    }

    /// Session starts and newly opened browsers share the same quiet,
    /// acknowledged warning policy. Refresh handler discovery once per start.
    func offerToBlockUncoveredBrowsers() {
        guard !Demo.isActive else { return }
        Self.refreshWebLinkHandlers()
        protectionFeedback.refresh()
    }

}

extension Enforcement {
    /// The app blocker's mode for these rules.
    var appMode: AppBlocker.Mode { mode == .block ? .block(apps) : .allow(apps) }
}

/// The popover's protection line, under the countdown.
struct ProtectionStatusLine: View {
    let model: NidusModel
    let status: ProtectionStatus
    @ObservedObject private var feedback: ProtectionFeedback

    init(model: NidusModel, status: ProtectionStatus) {
        self.model = model
        self.status = status
        feedback = model.protectionFeedback
    }

    var body: some View {
        Button { feedback.showingFixes = true } label: {
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
        }
        .buttonStyle(.plain)
        .help("Review protection and fixes")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Protection: \(status.line). Review fixes")
        .popover(isPresented: $feedback.showingFixes) {
            ProtectionFixesView(model: model)
        }
        .onDisappear { feedback.showingFixes = false }
    }
}
