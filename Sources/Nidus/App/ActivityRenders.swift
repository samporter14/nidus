import AppKit
import SwiftUI

/// Fictional sessions used only in an isolated render/demo environment.
@MainActor
extension NidusModel {
    func seedActivityPreview() {
        guard Demo.isActive, let history = controller?.history else { return }
        history.clear()
        activityTrackingEnabled = true
        let calendar = Calendar.current
        let project = UUID(uuidString: "B29523E0-0880-4541-B1BF-B7204B948CC0")!
        let grant = UUID(uuidString: "F8C4C904-1DB8-4929-9A1E-47C9399D21D1")!
        for day in (0..<35).reversed() where day % 7 != 5 {
            let date = calendar.date(byAdding: .day, value: -day, to: calendar.startOfDay(for: Date()))!
            let start = min(date.addingTimeInterval(9 * 3600), Date().addingTimeInterval(-7200))
            let factor = Double(1 + day % 3) / 2
            let rows: [FocusActivity] = [
                .init(appID: "com.anthropic.operon", appName: "Claude Science", title: "Interpreting the pilot results", seconds: 19 * 60 * factor),
                .init(appID: "com.apple.Safari", appName: "Safari", site: "Google Docs", title: "Manuscript · Discussion", seconds: 49 * 60 * factor),
                .init(appID: "com.microsoft.Word", appName: "Microsoft Word", title: "Specific Aims", seconds: 22 * 60 * factor),
                .init(appID: "local.sam.bench", appName: "Capsid", seconds: 10 * 60 * factor)
            ]
            let total = rows.reduce(0) { $0 + $1.seconds }
            var entry = SessionEntry(start: start, end: start.addingTimeInterval(total + 180), focused: total + 180,
                                     planned: total + 180, outcome: .completed,
                                     goal: day % 2 == 0 ? "Make the discussion clearer" : "Refine the central hypothesis",
                                     finished: true, projectID: day % 2 == 0 ? project : grant,
                                     projectName: day % 2 == 0 ? "Manuscript" : "Grant renewal")
            entry.activity = rows
            var cursor = start
            entry.activitySegments = rows.map { row in
                let segment = FocusActivitySegment(start: cursor, end: cursor.addingTimeInterval(row.seconds),
                                                   appID: row.appID, appName: row.appName,
                                                   site: row.site, title: row.title)
                cursor = segment.end
                return segment
            }
            entry.activityTimelineTruncated = false
            for row in rows {
                entry.foreground[row.appID, default: 0] += row.seconds
                entry.names[row.appID] = row.appName
            }
            history.append(entry)
            seedDailyRecord(on: date, session: entry, sites: day % 3)
        }
        controller?.activityRecorder.store.flush()
        controller?.bumpActivityDayVersion()
        objectWillChange.send()
    }

    /// A fictional day around that fictional session: a morning, lunch away,
    /// an afternoon. Goes only into the render's throwaway folder.
    private func seedDailyRecord(on date: Date, session: SessionEntry, sites: Int) {
        guard let recorder = controller?.activityRecorder else { return }
        let word = ("com.microsoft.Word", "Microsoft Word"), safari = ("com.apple.Safari", "Safari")
        let chrome = ("com.google.Chrome", "Google Chrome"), mail = ("com.apple.mail", "Mail"), capsid = ("local.sam.bench", "Capsid")
        let domains = ["nature.com", "pubmed.ncbi.nlm.nih.gov", "biorxiv.org", "uniprot.org"]
        var log = ActivityDayLog(day: ActivityDayLog.key(for: date, calendar: .current))
        var run = 0
        func add(_ hour: Double, _ minutes: Double, _ app: (String, String), site: String? = nil, title: String? = nil) {
            let start = date.addingTimeInterval(hour * 3600)
            let end = min(start.addingTimeInterval(minutes * 60), Date())
            guard end > start else { return }
            run += 1
            log.add(FocusActivitySegment(start: start, end: end, appID: app.0, appName: app.1, site: site, title: title, continuity: run))
        }
        add(8.4, 22, mail)
        for row in session.activitySegments ?? [] {
            log.add(FocusActivitySegment(start: row.start, end: row.end, appID: row.appID, appName: row.appName,
                                         site: row.site, title: row.title, continuity: run))
        }
        add(11.2, 34, chrome, site: domains[sites], title: "A fictional review article")
        add(11.8, 18, safari, site: domains[(sites + 1) % 4])
        add(13.3, 46, word, title: "Specific Aims")
        add(14.1, 24, chrome, site: domains[(sites + 2) % 4])
        add(14.5, 40, capsid)
        add(15.3, 28, mail)
        add(15.8, 62, word, title: "Manuscript · Results")
        add(17.0, 21, safari, site: domains[3])
        recorder.store.enqueue(.write(log))
    }
}

extension RenderSurfaces {
    static func renderActivity(model: NidusModel, settings: SettingsWindowController, in directory: URL) async {
        await shootSettings(model, settings, tab: .activity, name: "activity-empty", height: 900, in: directory)
        model.seedActivityPreview()
        await shootSettings(model, settings, tab: .activity, name: "activity-overview", height: 1500, in: directory)
        await shoot(FocusActivityPage(model: model, initialPeriod: .month), width: 640, height: 1500,
                    name: "activity-month", in: directory)
        await shoot(FocusActivityPage(model: model, initialPeriod: .week), width: 640, height: 1500,
                    name: "activity-week", in: directory)
        if let entry = model.activitySessions.last {
            await shoot(ActivitySessionRecap(entry: entry), width: 520, height: 680,
                        name: "activity-recap", in: directory)
        }
        await shootWindow(settings, page: "activity", name: "activity-window", in: directory)
    }
}

extension RenderSurfaces {
    /// The popover's two pieces, each state, in light and dark. Empty and off
    /// come first: they need a day with nothing counted.
    static func renderPopoverSurfaces(model: NidusModel, in directory: URL) async {
        // The offscreen window has no popover material, so each theme gets
        // its window color behind the popover.
        func popover(moreOpen: Bool = false) -> some View {
            NidusPopover(model: model, moreOpen: moreOpen).background(Color(nsColor: .windowBackgroundColor))
        }
        model.runHarnessScenario("idle")
        model.goalDraft = ""
        await shoot(popover(), width: 440, name: "idle-empty", in: directory)
        model.activityTrackingEnabled = false
        await shoot(popover(), width: 440, name: "idle-off", in: directory)
        model.activityTrackingEnabled = true
        model.seedActivityPreview()
        await shoot(popover(), width: 440, name: "idle-data", in: directory)
        await shoot(popover(moreOpen: true), width: 440, name: "idle-more-open", in: directory)
        model.runHarnessScenario("running")
        await shoot(popover(), width: 440, name: "running", in: directory)
        model.runHarnessScenario("break")
        await shoot(popover(), width: 440, name: "break", in: directory)
    }
}
