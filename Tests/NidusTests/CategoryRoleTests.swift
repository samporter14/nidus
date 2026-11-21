import Foundation
import Testing
@testable import Nidus

/// Category roles: work, neutral, distracting.
@Suite("Category roles")
struct CategoryRoleTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        return calendar
    }()
    private var day: Date { Self.calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))! }
    private func at(_ minutes: Double) -> Date { day.addingTimeInterval(minutes * 60) }

    private func category(_ id: String, apps: [String], role: FocusCategory.Role) -> FocusCategory {
        FocusCategory(id: id, name: id, symbol: "circle", apps: apps.map { BlockedApp(bundleID: $0, name: $0) },
                      websites: [], role: role)
    }

    private func categorizer(workApps: [String] = ["w.app"], _ categories: [FocusCategory]) -> ActivityCategorizer {
        var work = FocusCategory.workSeed
        work.apps = workApps.map { BlockedApp(bundleID: $0, name: $0) }
        return ActivityCategorizer(categories: categories, work: work)
    }

    private func stretch(_ app: String, _ from: Double, _ to: Double) -> FocusActivitySegment {
        FocusActivitySegment(start: at(from), end: at(to), appID: app, appName: app)
    }

    // MARK: Decoding

    private func decode(_ json: String) throws -> FocusCategory {
        try JSONDecoder().decode(FocusCategory.self, from: Data(json.utf8))
    }

    private func old(_ id: String) -> String {
        #"{"id":"\#(id)","name":"X","symbol":"circle","apps":[],"websites":[]}"#
    }

    @Test func oldCategoriesDecodeAsDistractingExceptTheNeutralPresets() throws {
        #expect(try decode(old("social")).role == .distracting)
        #expect(try decode(old(UUID().uuidString)).role == .distracting)
        #expect(try decode(old("work")).role == .work)
        for id in ["ai-chat", "mail", "messaging"] { #expect(try decode(old(id)).role == .neutral) }
    }

    @Test func aSavedRoleWinsAndRoundTrips() throws {
        var mail = try decode(old("mail"))
        mail.role = .distracting
        let back = try JSONDecoder().decode(FocusCategory.self, from: JSONEncoder().encode(mail))
        #expect(back.role == .distracting)
        let json = #"{"id":"social","name":"X","symbol":"circle","apps":[],"websites":[],"role":"neutral"}"#
        #expect(try decode(json).role == .neutral)
    }

    @Test func anUnreadableRoleFallsBackToTheDefault() throws {
        let json = #"{"id":"mail","name":"X","symbol":"circle","apps":[],"websites":[],"role":"bogus"}"#
        #expect(try decode(json).role == .neutral)
    }

    @Test func builtInPresetsCarryTheirRoles() {
        let roles = Dictionary(uniqueKeysWithValues: (FocusCategory.presets).map { ($0.id, $0.role) })
        for id in ["mail", "messaging", "ai-chat"] { #expect(roles[id] == .neutral) }
        for id in ["social", "video", "news", "shopping", "games"] { #expect(roles[id] == .distracting) }
    }

    // MARK: The helper

    @Test func theHelperReadsRolesAndLeavesUncategorizedOut() {
        let c = categorizer([category("a", apps: ["a.app"], role: .distracting), category("b", apps: ["b.app"], role: .neutral),
                             category("c", apps: ["c.app"], role: .work)])
        #expect(c.role(forGroup: ActivityCategorizer.workID) == .work)
        #expect(c.role(forGroup: "a") == .distracting)
        #expect(c.role(forGroup: "b") == .neutral)
        #expect(c.role(forGroup: "c") == .work)
        #expect(c.role(forGroup: nil) == nil)
        #expect(c.role(forGroup: "gone") == nil)
        #expect(c.isDistracting(group: "a"))
        #expect(!c.isDistracting(group: "b") && !c.isDistracting(group: nil))
    }

    // MARK: Drift

    private func chains(_ c: ActivityCategorizer, _ stretches: [FocusActivitySegment]) -> [ActivityDriftChain] {
        ActivityDrift.chains(in: stretches, categorizer: c)
    }

    @Test func neutralTimeIsNeverDrift() {
        let neutral = categorizer([category("chat", apps: ["chat.app"], role: .neutral)])
        #expect(chains(neutral, [stretch("w.app", 0, 10), stretch("chat.app", 10, 20)]).isEmpty)
        let distracting = categorizer([category("chat", apps: ["chat.app"], role: .distracting)])
        #expect(chains(distracting, [stretch("w.app", 0, 10), stretch("chat.app", 10, 20)]).count == 1)
    }

    @Test func driftFromAWorkRoleCategoryCountsAsComingFromWork() {
        let c = categorizer([category("code", apps: ["code.app"], role: .work),
                             category("feed", apps: ["feed.app"], role: .distracting)])
        let found = chains(c, [stretch("code.app", 0, 10), stretch("feed.app", 10, 20)])
        #expect(found.count == 1)
        #expect(found.first?.fromWork == true)
    }

    // MARK: Heatmap and widget

    @Test func theHeatmapFoldsNeutralIntoOther() {
        let c = categorizer([category("chat", apps: ["chat.app"], role: .neutral), category("feed", apps: ["feed.app"], role: .distracting),
                             category("code", apps: ["code.app"], role: .work)])
        let map = ActivityHeatmap(stretches: [stretch("chat.app", 600, 615), stretch("feed.app", 615, 630), stretch("code.app", 630, 645)],
                                  categorizer: c, calendar: Self.calendar)
        let cell = map.cells.reduce(into: ActivityHeatmap.Cell()) {
            $0.work += $1.work; $0.distraction += $1.distraction; $0.other += $1.other
        }
        #expect(cell.other == 15 * 60)
        #expect(cell.distraction == 15 * 60)
        #expect(cell.work == 15 * 60)
    }

    @Test func theWidgetCountsNeutralAsOtherAndWorkRoleAsWork() throws {
        let c = categorizer([category("chat", apps: ["chat.app"], role: .neutral), category("feed", apps: ["feed.app"], role: .distracting),
                             category("code", apps: ["code.app"], role: .work)])
        var log = ActivityDayLog(day: ActivityDayLog.key(for: day, calendar: Self.calendar))
        log.stretches = [stretch("w.app", 0, 30), stretch("code.app", 30, 50), stretch("chat.app", 50, 70), stretch("feed.app", 70, 80)]
        let today = ActivityTodaySummary.build(log: log, categorizer: c, calendar: Self.calendar)
        #expect(today.work == 50 * 60)
        #expect(today.other == 20 * 60)
        #expect(today.distracting == 10 * 60)
        // The shape the widget decodes is unchanged.
        let json = try JSONEncoder().encode(today)
        let kinds = (try JSONSerialization.jsonObject(with: json) as? [String: Any])?["bands"] as? [[String: Any]] ?? []
        #expect(Set(kinds.compactMap { $0["kind"] as? String }).isSubset(of: ["work", "distracting", "other"]))
    }

    @Test func howMuchWorkCountsEveryWorkRoleCategory() {
        let c = categorizer([category("code", apps: ["code.app"], role: .work), category("chat", apps: ["chat.app"], role: .neutral)])
        var log = ActivityDayLog(day: ActivityDayLog.key(for: day, calendar: Self.calendar))
        log.stretches = [stretch("w.app", 0, 30), stretch("code.app", 30, 60), stretch("chat.app", 60, 90)]
        let today = ActivityTodaySummary.build(log: log, categorizer: c, calendar: Self.calendar)
        #expect(ActivityTodaySummary.workMinutes(today) == 60)
    }
}
