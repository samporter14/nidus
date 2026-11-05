//
//  ActivityExport.swift
//  Nidus
//
//  A separate, opt-in detailed CSV. The longstanding session CSV schema
//  remains stable for the tools that already consume it.
//

import Foundation

enum ActivityExport {
    static let columns = ["date", "start", "end", "app", "host", "title", "url", "in_focus", "project", "goal", "seconds"]

    /// One row a stretch, cut where a session starts or ends so `in_focus` is
    /// true of the whole row. A session with no daily record behind it gives
    /// its own rows, spanning the session.
    static func csv(logs: [ActivityDayLog], sessions: [SessionEntry], calendar: Calendar = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stretches = logs.flatMap(\.stretches)
        var rows: [(start: Date, fields: [String])] = []
        func add(_ start: Date, _ end: Date, app: String, site: String?, title: String?, url: String?,
                 session: SessionEntry?, seconds: TimeInterval) {
            rows.append((start, [ActivityDayLog.key(for: start, calendar: calendar), formatter.string(from: start),
                                 formatter.string(from: end), app, site ?? "", title ?? "", url ?? "",
                                 session == nil ? "false" : "true", session?.projectName ?? "", session?.goal ?? "",
                                 String(seconds)]))
        }
        for stretch in stretches {
            let overlapping = sessions.filter { $0.end > stretch.start && $0.start < stretch.end }
            let inside = overlapping.flatMap { [$0.start, $0.end] }.filter { $0 > stretch.start && $0 < stretch.end }
            let cuts = Array(Set(inside + [stretch.start, stretch.end])).sorted()
            for (start, end) in zip(cuts, cuts.dropFirst()) {
                let middle = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
                add(start, end, app: stretch.appName, site: stretch.site, title: stretch.title, url: stretch.url,
                    session: overlapping.first { $0.start <= middle && middle < $0.end },
                    seconds: end.timeIntervalSince(start))
            }
        }
        for session in sessions where !stretches.contains(where: { $0.end > session.start && $0.start < session.end }) {
            let details: [FocusActivity]
            if let activity = session.activity {
                details = activity
            } else {
                // Older sessions recorded only totals by application.
                details = session.foreground.keys.sorted().map { appID in
                    FocusActivity(id: appID, appID: appID, appName: session.names[appID] ?? appID,
                                  seconds: session.foreground[appID] ?? 0)
                }
            }
            for row in details where row.seconds.isFinite && row.seconds > 0 {
                add(session.start, session.end, app: row.appName, site: row.site, title: row.title, url: nil,
                    session: session, seconds: row.seconds)
            }
        }
        rows.sort { $0.start < $1.start }
        let lines = [columns.joined(separator: ",")] + rows.map { $0.fields.map(field).joined(separator: ",") }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180 quoting plus a leading apostrophe for spreadsheet formulas.
    private static func field(_ text: String) -> String {
        let first = text.drop(while: { $0.isWhitespace }).first
        let safe = first.map({ "=+-@".contains($0) }) == true ? "'" + text : text
        if safe.contains(",") || safe.contains("\"") || safe.contains("\n") || safe.contains("\r") {
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return safe
    }
}
