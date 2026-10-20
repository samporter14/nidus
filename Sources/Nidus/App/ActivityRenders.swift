#if DEBUG
import AppKit
import SwiftUI

/// Fictional sessions used only in an isolated render/demo environment.
@MainActor
extension NidusModel {
    func seedActivityPreview() {
        guard Demo.isActive, let history = controller?.history else { return }
        history.clear()
        activityTrackingEnabled = true
        activityDocumentTitlesEnabled = true
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
        }
        objectWillChange.send()
    }
}

extension RenderSurfaces {
    static func renderActivity(model: NidusModel, settings: SettingsWindowController, in directory: URL) async {
        await shootSettings(model, settings, tab: .activity, name: "activity-empty", height: 900, in: directory)
        model.seedActivityPreview()
        await shootSettings(model, settings, tab: .activity, name: "activity-overview", height: 1500, in: directory)
        await shoot(FocusActivityPage(model: model, initialPeriod: .month), width: 640, height: 1500,
                    name: "activity-month", in: directory)
        if let entry = model.activitySessions.last {
            await shoot(ActivitySessionRecap(entry: entry), width: 520, height: 680,
                        name: "activity-recap", in: directory)
        }
        await shootWindow(settings, page: "activity", name: "activity-window", in: directory)
    }
}

#endif
