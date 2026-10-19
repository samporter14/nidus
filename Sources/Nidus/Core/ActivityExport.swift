//
//  ActivityExport.swift
//  Nidus
//
//  A separate, opt-in detailed CSV. The longstanding session CSV schema
//  remains stable for the tools that already consume it.
//

import Foundation

enum ActivityExport {
    static let columns = ["session_start", "session_end", "project", "goal", "app", "site", "title", "seconds"]

    static func csv(sessions: [SessionEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = [columns.joined(separator: ",")]
        for session in sessions {
            let rows: [FocusActivity]
            if let activity = session.activity {
                rows = activity
            } else {
                // Older sessions recorded only totals by application.
                rows = session.foreground.keys.sorted().map { appID in
                    FocusActivity(id: appID, appID: appID, appName: session.names[appID] ?? appID,
                                  seconds: session.foreground[appID] ?? 0)
                }
            }
            for row in rows where row.seconds.isFinite && row.seconds > 0 {
                let fields = [
                    formatter.string(from: session.start),
                    formatter.string(from: session.end),
                    session.projectName ?? "",
                    session.goal,
                    row.appName,
                    row.site ?? "",
                    row.title ?? "",
                    String(row.seconds),
                ]
                lines.append(fields.map(field).joined(separator: ","))
            }
        }
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
