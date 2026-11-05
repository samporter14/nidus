import AppKit
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers

extension NidusModel.Key {
    static let activityTracking = "activityTrackingEnabled"
    static let activityExcluded = "activityExcludedApps"
    static let activityAllDay = "activityAllDayEnabled"
    static let activityIdleMinutes = "activityIdleMinutes"
    static let activityRetentionDays = "activityRetentionDays"
    static let activityPausedUntil = "activityPausedUntil"
}

/// The choices Activity settings offers, in minutes and in days (0: forever).
enum ActivityChoices {
    static let idleMinutes = [2, 5, 10, 15, 30]
    static let retentionDays = [30, 90, 365, 0]
    static func retentionName(_ days: Int) -> String {
        switch days {
        case 0: return "Forever"
        case 365: return "1 year"
        default: return "\(days) days"
        }
    }
}

extension NidusModel {
    /// Sessions as Activity shows them, without excluded apps.
    var activitySessions: [SessionEntry] {
        let excluded = activityExcludedApps
        return (controller?.history.sessions ?? []).map { $0.hiding(excluded) }
    }

    /// Today for the popover: the day's record, today's sessions and the
    /// session running now. Reads what the recorder already holds.
    func todayOverview(now: Date = Date()) -> TodayOverview? {
        guard let controller else { return nil }
        let recorder = controller.activityRecorder
        var log = recorder.today()
        // The recorder is off in Demo mode, so show the day seeded on disk.
        if Demo.isActive, let seeded = recorder.store.load(day: ActivityDayLog.key(for: now, calendar: .current)) { log = seeded }
        var live: ActivityRibbon.Focus?
        var liveFocused: TimeInterval = 0
        if controller.engine.isRunning, let session = controller.engine.session, session.startedAt < now {
            live = ActivityRibbon.Focus(id: "live", sessionID: nil, start: session.startedAt, end: now,
                                        name: session.plan.goal.isEmpty ? "Focus" : session.plan.goal)
            // Pauses are already out of `elapsed`.
            liveFocused = controller.engine.elapsed ?? 0
        }
        return TodayOverview(log: log.hiding(activityExcludedApps), sessions: activitySessions, live: live, liveFocused: liveFocused,
                             tracking: recordsHistory && activityTrackingEnabled && activityAllDayEnabled, now: now)
    }

    var activityTrackingEnabled: Bool {
        get { preference(Key.activityTracking, default: true) }
        set { setPreference(newValue, Key.activityTracking); applyActivitySettings() }
    }
    var activityExcludedApps: Set<String> {
        get { preference(Key.activityExcluded, default: Set<String>()) }
        set { setPreference(newValue, Key.activityExcluded); applyActivitySettings() }
    }
    /// Only meaningful with Activity and history on.
    var activityAllDayEnabled: Bool {
        get { preference(Key.activityAllDay, default: true) }
        set { setPreference(newValue, Key.activityAllDay); applyActivitySettings() }
    }
    var activityIdleMinutes: Int {
        get { preference(Key.activityIdleMinutes, default: Int(ActivityRecorder.defaultIdleCutoff / 60)) }
        set { setPreference(newValue, Key.activityIdleMinutes); applyActivitySettings() }
    }
    var activityRetentionDays: Int {
        get { preference(Key.activityRetentionDays, default: ActivityRecorder.defaultRetentionDays) }
        set { setPreference(newValue, Key.activityRetentionDays); applyActivitySettings() }
    }
    var activityPausedUntil: Date? {
        get {
            let seconds = preference(Key.activityPausedUntil, default: 0.0)
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        }
        set {
            setPreference(newValue?.timeIntervalSince1970 ?? 0, Key.activityPausedUntil)
            applyActivitySettings()
        }
    }
    func applyActivitySettings() {
        controller?.activityTrackingEnabled = recordsHistory && activityTrackingEnabled
        controller?.activityDocumentTitlesEnabled = true
        controller?.activityExcludedApps = activityExcludedApps
        controller?.activityAllDayEnabled = activityAllDayEnabled
        controller?.activityIdleCutoff = TimeInterval(max(1, activityIdleMinutes) * 60)
        controller?.activityRetentionDays = max(0, activityRetentionDays)
        controller?.activityPausedUntil = activityPausedUntil
    }

    /// There is something to pause: Activity is collecting, now or at the
    /// next session.
    var canPauseActivity: Bool { recordsHistory && activityTrackingEnabled }
    /// When a pause still in force ends.
    var activityPauseEnd: Date? { activityPausedUntil.flatMap { $0 > Date() ? $0 : nil } }
    func pauseActivityForAnHour() { activityPausedUntil = Date().addingTimeInterval(3600) }
    func resumeActivity() { activityPausedUntil = nil }
    func openActivity(sessionID: UUID? = nil) {
        if let sessionID {
            host?.workspace.openSettingsPage("activity:" + sessionID.uuidString, title: "Session activity")
        } else {
            openSettings(.activity)
        }
    }
    func exportActivity() {
        let sessions = activitySessions
        let excluded = activityExcludedApps
        let recorder = controller?.activityRecorder
        Task { @MainActor in
            var logs = await recorder?.store.loadAll() ?? []
            if let recorder, recorder.isRecording {
                let today = recorder.today()
                logs.removeAll { $0.day == today.day }
                logs.append(today)
            }
            guard !sessions.isEmpty || !logs.isEmpty else { return }
            saveExport(ActivityExport.csv(logs: logs.map { $0.hiding(excluded) }, sessions: sessions))
        }
    }

    private func saveExport(_ text: String) {
        let data = Data(text.utf8)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Nidus activity \(Date().formatted(.iso8601.year().month().day())).csv"
        panel.message = "App, website and document durations."
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

/// Permission prompts happen only from a button.
struct ActivityTrackingControls: View {
    @ObservedObject var model: NidusModel
    @State private var expanded = false
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var permissionNotice = ""
    @State private var confirmingClear = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Track activity", isOn: model.binding(\.activityTrackingEnabled))
                if !model.recordsHistory {
                    Label("Session history is off, so nothing is being recorded.", systemImage: "pause.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open history settings") { model.openStats() }
                }
                if model.activityTrackingEnabled {
                    Toggle("Track all day", isOn: model.binding(\.activityAllDayEnabled))
                    if model.activityAllDayEnabled {
                        Picker("Stop counting after", selection: model.binding(\.activityIdleMinutes)) {
                            ForEach(ActivityChoices.idleMinutes, id: \.self) { minutes in
                                Text("\(minutes) minutes without input").tag(minutes)
                            }
                        }
                        Picker("Keep daily records for", selection: model.binding(\.activityRetentionDays)) {
                            ForEach(ActivityChoices.retentionDays, id: \.self) { days in
                                Text(ActivityChoices.retentionName(days)).tag(days)
                            }
                        }
                    }
                    Divider()
                    HStack {
                        Label(accessibilityGranted ? "Window titles are on" : "Window titles need access",
                              systemImage: accessibilityGranted ? "checkmark.circle" : "lock")
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
                    Spacer()
                    Button("Clear history…", role: .destructive) { confirmingClear = true }
                }
                .confirmationDialog("Clear your focus history?", isPresented: $confirmingClear) {
                    Button("Clear history", role: .destructive, action: model.clearHistory)
                } message: {
                    Text(FocusStatsPage.clearHistoryMessage)
                }
            }
            .padding(.top, 14)
        } label: {
            Label("Tracking", systemImage: "slider.horizontal.3")
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
                ? "\(browser.name) is ready for website recognition."
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
