import AppKit
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers

extension NidusModel.Key {
    static let activityTracking = "activityTrackingEnabled"
    static let activityTitles = "activityDocumentTitlesEnabled"
    static let activityExcluded = "activityExcludedApps"
}

extension NidusModel {
    /// Whether any recorded session still holds a document or conversation name.
    var hasSavedActivityTitles: Bool { controller?.history.hasActivityTitles ?? false }

    /// Takes the names out of every recorded session and the running one,
    /// keeping their times. Asked for from Settings, behind a confirmation.
    func removeSavedActivityTitles() { controller?.removeActivityTitles() }

    var activitySessions: [SessionEntry] { controller?.history.sessions ?? [] }

    var activityTrackingEnabled: Bool {
        get { preference(Key.activityTracking, default: false) }
        set { setPreference(newValue, Key.activityTracking); applyActivitySettings() }
    }
    var activityDocumentTitlesEnabled: Bool {
        get { preference(Key.activityTitles, default: false) }
        set { setPreference(newValue, Key.activityTitles); applyActivitySettings() }
    }
    var activityExcludedApps: Set<String> {
        get { preference(Key.activityExcluded, default: Set<String>()) }
        set { setPreference(newValue, Key.activityExcluded); applyActivitySettings() }
    }
    func applyActivitySettings() {
        controller?.activityTrackingEnabled = recordsHistory && activityTrackingEnabled
        controller?.activityDocumentTitlesEnabled = activityDocumentTitlesEnabled
        controller?.activityExcludedApps = activityExcludedApps
    }
    func openActivity(sessionID: UUID? = nil) {
        if let sessionID {
            host?.workspace.openSettingsPage("activity:" + sessionID.uuidString, title: "Session activity")
        } else {
            openSettings(.activity)
        }
    }
    func exportActivity() {
        let sessions = activitySessions
        guard !sessions.isEmpty else { return }
        let data = Data(ActivityExport.csv(sessions: sessions).utf8)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Nidus activity \(Date().formatted(.iso8601.year().month().day())).csv"
        panel.message = "App, website and document durations. Includes document names when recorded."
        let write: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) }
            catch { NSAlert(error: error).runModal() }
        }
        if let window = host?.workspace.settings.window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else { write(panel.runModal()) }
    }
}

/// Local, session-scoped collection. Permission prompts happen only from a button.
struct ActivityTrackingControls: View {
    @ObservedObject var model: NidusModel
    @State private var expanded = false
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var permissionNotice = ""
    @State private var confirmsRemovingTitles = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Record activity during focus sessions", isOn: model.binding(\.activityTrackingEnabled))
                if !model.recordsHistory {
                    Label("Session history is off. Activity is not being recorded.", systemImage: "pause.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open history settings") { model.openStats() }
                }
                if model.activityTrackingEnabled {
                    Text("Only the app in front counts. Recognized websites can be separated from browser time when access is allowed. Reading still counts; pauses, breaks and sleep do not.")
                        .font(.callout).foregroundStyle(.secondary)
                    Toggle("Include document and conversation names", isOn: model.binding(\.activityDocumentTitlesEnabled))
                    Text("Names may contain private information. Nidus reads selected tab or front-window titles and names explicitly shared by Capsid, never document contents. Names stay in local session history and are included in exports.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.activityDocumentTitlesEnabled {
                        HStack {
                            Label(accessibilityGranted ? "Window-title access is allowed" : "Window-title access is needed for Word and Claude", systemImage: accessibilityGranted ? "checkmark.circle" : "lock")
                                .font(.callout)
                            Spacer()
                            Button(accessibilityGranted ? "Review access" : "Allow access") {
                                if !accessibilityGranted {
                                    _ = model.controller?.requestActivityAccessibilityAccess()
                                }
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        Text("Document names: Word, Claude, Google Docs, and Capsid when sharing is enabled in Capsid settings. Claude Science’s local browser interface is recognized as a service; its conversation names are unavailable. Different documents with the same title are combined.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(BrowserProfile.known.filter(\.isInstalled), id: \.bundleID) { browser in
                        HStack {
                            Text(browser.name).font(.callout)
                            Spacer()
                            Button("Allow website access") { request(browser) }
                        }
                    }
                    if !permissionNotice.isEmpty {
                        Text(permissionNotice).font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack {
                        Text("Excluded apps").font(.callout.weight(.medium))
                        Spacer()
                        Button("Add app…", action: chooseExcludedApp)
                    }
                    if model.activityExcludedApps.isEmpty {
                        Text("No exclusions. Add an app to leave it out of future activity measurements.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.activityExcludedApps.sorted(), id: \.self) { bundleID in
                        HStack {
                            Text(appName(bundleID)).font(.callout)
                            Spacer()
                            Button("Remove") { model.activityExcludedApps.remove(bundleID) }
                        }
                    }
                }
                Divider()
                HStack {
                    Button("Export activity…", action: model.exportActivity)
                        .disabled(model.activitySessions.isEmpty)
                    Spacer()
                    Button("Remove saved names…") { confirmsRemovingTitles = true }
                        .disabled(!model.hasSavedActivityTitles)
                        .help("Takes document and conversation names out of your history. Times stay.")
                    Button("History & deletion") { model.openStats() }
                }
                .confirmationDialog("Remove saved names?", isPresented: $confirmsRemovingTitles) {
                    Button("Remove Names", role: .destructive) { model.removeSavedActivityTitles() }
                } message: {
                    Text("Document and conversation names are taken out of every recorded session. Times, apps and websites stay. This can't be undone.")
                }
                Text("Kept on this Mac. Changing these settings affects future collection. Remove saved names takes names out of past sessions; Clear history removes everything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 14)
        } label: {
            Label("Tracking & privacy", systemImage: "lock.shield")
                .font(.system(size: 14, weight: .medium))
        }
        .tint(FocusPalette.clay)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AXIsProcessTrusted()
        }
    }

    private func request(_ browser: BrowserProfile) {
        guard AppleEventTarget(runningBundleID: browser.bundleID) != nil else {
            permissionNotice = "Open \(browser.name), then allow website access here."
            return
        }
        model.askBrowserAccess(browser) {
            let error = AppleEventTarget(runningBundleID: browser.bundleID)?.automationPermission(ask: false)
            permissionNotice = error == nil
                ? "\(browser.name) is ready for website recognition during your next session."
                : "Access is not available yet. Review Nidus under Privacy & Security → Automation."
        }
    }

    private func chooseExcludedApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose apps to exclude from future activity tracking."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { model.activityExcludedApps.insert(id) }
        }
    }
    private func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path)
    }
}
