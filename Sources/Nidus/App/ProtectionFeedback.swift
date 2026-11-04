// Protection feedback follows app launches, permission changes and session
// events. It has no polling timer and retains no presentation after dismissal.
import AppKit
import Combine
import SwiftUI

@MainActor
final class ProtectionFeedback: ObservableObject {
    static let acknowledgementKey = "protectionAcknowledgements"
    @Published var showingFixes = false
    private weak var model: NidusModel?
    private var observers: Set<AnyCancellable> = []
    private var pending: Task<Void, Never>?
    private var memory = ProtectionNoticeMemory()

    func start(model: NidusModel) {
        stop()
        self.model = model
        memory = ProtectionNoticeMemory(acknowledged: model.host?.preferences.value(
            forKey: Self.acknowledgementKey, default: [String]()) ?? [])
        let center = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.publisher(for: event)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] note in
                    if event == NSWorkspace.didLaunchApplicationNotification,
                       let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                       app.activationPolicy == .regular,
                       let id = app.bundleIdentifier, !NidusModel.cachedWebLinkHandlers.contains(id) {
                        NidusModel.refreshWebLinkHandlers()
                    }
                    self?.model?.objectWillChange.send()
                    self?.refresh()
                }
                .store(in: &observers)
        }
        refresh()
    }

    func stop() {
        pending?.cancel()
        pending = nil
        observers.removeAll()
        model?.host?.hud.dismiss(id: NidusModel.uncoveredBrowserHUDID)
        showingFixes = false
        model = nil
    }

    /// A short, cancellable settling delay avoids replacing a session-start
    /// card or warning about a browser that has already quit or been blocked.
    func refresh() {
        guard let model, !Demo.isActive, model.isActive, model.engine?.enforcement != nil else {
            pending?.cancel()
            pending = nil
            model?.host?.hud.dismiss(id: NidusModel.uncoveredBrowserHUDID)
            return
        }
        let keys = model.protectionIssues.map(\.id)
        let fresh = memory.nextWarnings(for: keys)
        guard !fresh.isEmpty else {
            pending?.cancel()
            pending = nil
            if keys.isEmpty { model.host?.hud.dismiss(id: NidusModel.uncoveredBrowserHUDID) }
            return
        }
        guard pending == nil else { return }
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.presentIfRelevant()
        }
    }

    func acknowledgeCurrent() {
        guard let model else { return }
        acknowledge(model.protectionIssues.map(\.id))
    }

    private func acknowledge(_ keys: [String]) {
        memory.acknowledge(keys)
        model?.host?.preferences.setValueQuietly(memory.acknowledged, forKey: Self.acknowledgementKey)
        model?.host?.hud.dismiss(id: NidusModel.uncoveredBrowserHUDID)
    }

    private func presentIfRelevant() {
        guard let model, let host = model.host, model.isActive, model.engine?.enforcement != nil else { return }
        let issues = model.protectionIssues
        let keys = memory.nextWarnings(for: issues.map(\.id))
        guard !keys.isEmpty else { return }
        let names = issues.filter { keys.contains($0.id) }.map(\.name)
        let title = "Sites aren’t blocked in \(ProtectionStatus.list(names))"
        let request = HUDRequest(id: NidusModel.uncoveredBrowserHUDID, duration: 8,
                                 accessibilityLabel: "\(title). Review fixes or acknowledge this warning.") { [weak self, weak model] in
            HStack(spacing: NidusSpacing.sm) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(Solanum.clayText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.system(size: 14, weight: .medium))
                    Text("Fixes are always in the protection line.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Button("Review…") {
                    self?.acknowledge(keys)
                    model?.openProtectionFixes()
                }
                .buttonStyle(.bordered)
                Button("Got it") { self?.acknowledge(keys) }
                    .buttonStyle(.borderless)
                    .help("Keep these warnings quiet; their protection status stays visible.")
            }
        }
        if host.hud.present(request) { memory.didPresent(keys) }
    }
}

struct ProtectionIssue: Identifiable {
    enum Kind: String { case consent, denied, unsupported }
    let bundleID: String
    let name: String
    let kind: Kind
    var id: String { "\(kind.rawValue):\(bundleID)" }
}

extension NidusModel {
    /// The actionable website gaps during a focus session. Breaks have no
    /// session app-block action; installed but closed browsers are absent too.
    var protectionIssues: [ProtectionIssue] {
        guard !Demo.isActive, isActive, let controller, let enforcement = engine?.enforcement,
              !(enforcement.mode == .block && enforcement.websites.isEmpty) else { return [] }
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        var issues: [ProtectionIssue] = []
        for browser in BrowserProfile.known where runningIDs.contains(browser.bundleID)
            && !AppBlocker.isBlocked(browser.bundleID, under: enforcement.appMode) {
            switch controller.browserAccess[browser.bundleID] {
            case .needsConsent?: issues.append(.init(bundleID: browser.bundleID, name: browser.shortName, kind: .consent))
            case .notPermitted?: issues.append(.init(bundleID: browser.bundleID, name: browser.shortName, kind: .denied))
            default: break
            }
        }
        let names = Dictionary(running.compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } },
                               uniquingKeysWith: { first, _ in first })
        let candidates = Self.cachedWebLinkHandlers + runningIDs.filter { UncoveredBrowsers.named[$0] != nil }
        let unsupported = UncoveredBrowsers.runningToOffer(candidates, running: runningIDs,
                                                          blockedAsApp: { AppBlocker.isBlocked($0, under: enforcement.appMode) })
        issues += unsupported.map { .init(bundleID: $0, name: names[$0] ?? UncoveredBrowsers.named[$0] ?? $0, kind: .unsupported) }
        return issues
    }

    func openProtectionFixes() {
        showPopover()
        protectionFeedback.showingFixes = true
    }

    func showProtectionSettings() {
        guard let entry = SettingsJumpIndex.entries.first(where: { $0.id == "browsers" }) else { return }
        settingsJump.open(entry)
    }
}

struct ProtectionFixesView: View {
    @ObservedObject var model: NidusModel

    var body: some View {
        VStack(alignment: .leading, spacing: NidusSpacing.md) {
            Text("Protection").font(.system(size: 15, weight: .semibold))
            if let status = model.protectionStatus {
                Text(verbatim: status.line).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(model.protectionIssues) { issue in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: issue.name).font(.system(size: 13, weight: .medium))
                    switch issue.kind {
                    case .consent:
                        Text("Allow Nidus to check this browser’s tabs.").font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Allow…") {
                            guard let browser = BrowserProfile.known.first(where: { $0.bundleID == issue.bundleID }) else { return }
                            model.askBrowserAccess(browser) { model.protectionFeedback.refresh() }
                        }
                    case .denied:
                        Text("Enable this browser under Nidus in Automation.").font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Open System Settings…", action: model.openAutomationSettings)
                    case .unsupported:
                        Text("This browser doesn’t support website blocking.").font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Block for this session") {
                            model.engine?.blockAppsForSession([issue.bundleID])
                            model.protectionFeedback.refresh()
                            model.objectWillChange.send()
                        }
                    }
                }
            }
            ForEach((model.controller?.refusedApps ?? [:]).keys.sorted(), id: \.self) { id in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: model.controller?.refusedApps[id] ?? id).font(.system(size: 13, weight: .medium))
                    Text("The app may be waiting for unsaved changes before it can quit.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Ask to quit again") {
                        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.terminate()
                    }
                }
            }
            Divider()
            HStack {
                Button("Browser settings…", action: model.showProtectionSettings)
                Spacer()
                if !model.protectionIssues.isEmpty {
                    Button("Got it") {
                        model.protectionFeedback.acknowledgeCurrent()
                        model.protectionFeedback.showingFixes = false
                    }
                    .help("Keep these warnings quiet; their protection status stays visible.")
                }
            }
        }
        .buttonStyle(.bordered)
        .padding(NidusSpacing.lg)
        .frame(width: 340)
    }
}
