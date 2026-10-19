import Foundation

/// Capsid publishes only an explicitly shared foreground context. Nothing is
/// requested from Capsid and no document contents or URLs enter this channel.
struct CapsidActivityContext: Codable, Sendable {
    var version: Int
    var pid: Int32
    var updatedAt: TimeInterval
    var projectName: String?
    var taskName: String?

    static func read(pid: Int32, now: Date = Date()) -> ActivityDetail? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Capsid/nidus-context.json")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8193), data.count <= 8192 else { return nil }
        return detail(data: data, pid: pid, now: now)
    }

    static func detail(data: Data, pid: Int32, now: Date) -> ActivityDetail? {
        guard data.count <= 8192,
              let context = try? JSONDecoder().decode(Self.self, from: data),
              context.version == 1, context.pid == pid, context.updatedAt.isFinite,
              now.timeIntervalSince1970 - context.updatedAt >= -2,
              now.timeIntervalSince1970 - context.updatedAt <= 15 else { return nil }
        let project = ActivityProbe.cleanTitle(context.projectName)
        let task = ActivityProbe.cleanTitle(context.taskName)
        guard let task else { return nil }
        let title = project.map { $0 == task ? task : "\($0) · \(task)" } ?? task
        return ActivityDetail(site: nil, title: ActivityProbe.cleanTitle(title))
    }
}
