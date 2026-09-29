//
//  StatsAndFeaturesTests.swift
//  NidusTests
//
//  1.1: apps opened at start, per-session counters, history and stats, and
//  loading what 1.0 saved.
//

import Foundation
import Testing
@testable import Nidus

@MainActor
struct LaunchAppsTests {
    @Test func appsOpenedAtStartAreNeverBlockedInBlockMode() {
        let h = Harness()
        var p = plan(25, apps: ["com.apple.dt.Xcode", "com.tinyspeck.slackmacgap"])
        p.launchApps = ["com.apple.dt.Xcode"]
        h.engine.start(p)
        #expect(h.engine.enforcement?.apps == ["com.tinyspeck.slackmacgap"])
    }

    @Test func appsOpenedAtStartAreAllowedInAllowMode() {
        let h = Harness()
        var p = plan(25, mode: .allow, apps: ["com.apple.Notes"], websites: [])
        p.launchApps = ["com.apple.dt.Xcode"]
        h.engine.start(p)
        #expect(h.engine.enforcement?.apps == ["com.apple.Notes", "com.apple.dt.Xcode"])
    }
}

@MainActor
struct CounterTests {
    @Test func blocksQuitsAndForegroundAreCountedAndSurviveARelaunch() {
        let h = Harness()
        h.engine.start(plan(25))
        h.engine.recordBlock("youtube.com", name: "youtube.com")
        h.engine.recordBlock("youtube.com", name: "youtube.com")
        h.engine.recordQuit("com.tinyspeck.slackmacgap", name: "Slack")
        h.engine.recordQuit("com.tinyspeck.slackmacgap", name: "Slack")
        h.engine.recordForeground("com.apple.dt.Xcode", name: "Xcode", seconds: 90)
        h.engine.checkpoint()

        let (engine, _) = h.relaunch()
        let s = engine.session
        #expect(s?.blocks["youtube.com"] == 2)
        #expect(s?.quitCounts["com.tinyspeck.slackmacgap"] == 2)
        #expect(s?.quitApps == ["com.tinyspeck.slackmacgap"], "the reopen list still holds each app once")
        #expect(s?.foreground["com.apple.dt.Xcode"] == 90)
        #expect(s?.names["com.tinyspeck.slackmacgap"] == "Slack")
    }

    @Test func foregroundOnlyCountsWhileRunning() {
        let h = Harness()
        h.engine.start(plan(25))
        h.engine.pause()
        h.engine.recordForeground("com.apple.dt.Xcode", name: "Xcode", seconds: 30)
        #expect(h.engine.session?.foreground.isEmpty == true)
    }

    @Test func theEndRecordsWhenAndHowLongWasFocused() {
        let h = Harness()
        h.engine.start(plan(25))
        h.clock.advance(10 * minute)
        h.engine.pause()
        h.clock.advance(30 * minute)
        h.engine.end()
        guard case .ended(.endedEarly, let final)? = h.events.last else { Issue.record("no end"); return }
        #expect(final.focusedTime == 10 * minute, "the pause is not focus")
        #expect(final.endedAt == h.clock.now)
    }

    @Test func aSessionThatExpiredWhileAwayCountsOnlyWhatWasSeen() {
        let h = Harness()
        h.engine.start(plan(25))
        h.clock.advance(7 * minute)
        h.engine.checkpoint()
        h.clock.advance(3 * 60 * minute)
        let (_, events) = h.relaunch()
        guard case .ended(.expiredWhileAway, let final)? = events.last else { Issue.record("no end"); return }
        #expect(final.focusedTime == 7 * minute)
    }
}

@MainActor
struct OlderFileTests {
    /// Exactly what 1.0 wrote: no counters, no launch apps, no shortcuts.
    static let v1 = """
    {"lastPlan":{"goal":"Write","duration":1500,"mode":"block","apps":["com.tinyspeck.slackmacgap"],
      "websites":["youtube.com"],"reopensQuitApps":false},
     "session":{"plan":{"goal":"Write","duration":1500,"mode":"block","apps":["com.tinyspeck.slackmacgap"],
      "websites":["youtube.com"],"reopensQuitApps":false},
      "startedAt":800000000,"phase":{"running":{"deadline":800001500}},"budget":1500,
      "snoozes":{},"quitApps":["com.tinyspeck.slackmacgap"]}}
    """

    @Test func whatVersionOneSavedStillLoads() throws {
        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(Self.v1.utf8))
        #expect(record.lastPlan?.goal == "Write")
        #expect(record.lastPlan?.launchApps == [])
        #expect(record.lastPlan?.startShortcut == nil)
        #expect(record.session?.quitApps == ["com.tinyspeck.slackmacgap"])
        #expect(record.session?.blocks == [:])
        #expect(record.session?.seenElapsed == 0)
    }

    @Test func newFieldsRoundTrip() throws {
        var p = plan(25)
        p.launchApps = ["com.apple.dt.Xcode"]
        p.startShortcut = "Focus on"
        p.endShortcut = "Focus off"
        let decoded = try JSONDecoder().decode(SessionPlan.self, from: JSONEncoder().encode(p))
        #expect(decoded == p)
    }
}

struct StatsTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2  // Monday
        return c
    }()
    /// Friday 25 September 2026, 15:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_790_348_400)

    static func day(_ offset: Int, hour: Int = 10) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .hour, value: hour, to: calendar.date(byAdding: .day, value: offset, to: start)!)!
    }

    static func entry(_ offset: Int, minutes: Double, outcome: SessionEndReason = .completed,
                      blocks: [String: Int] = [:], quits: [String: Int] = [:], fg: [String: TimeInterval] = [:],
                      names: [String: String] = [:]) -> SessionEntry {
        let start = day(offset)
        return SessionEntry(start: start, end: start.addingTimeInterval(minutes * 60), focused: minutes * 60,
                            planned: minutes * 60, outcome: outcome, blocks: blocks, quits: quits, foreground: fg, names: names)
    }

    func stats(_ sessions: [SessionEntry]) -> FocusStats {
        FocusStats(sessions: sessions, now: Self.now, calendar: Self.calendar)
    }

    @Test func emptyHistory() {
        let s = stats([])
        #expect(s.isEmpty)
        #expect(s.currentStreak == 0 && s.longestStreak == 0)
        #expect(s.weeks.count == 26 && s.weeks.allSatisfy { $0.count == 7 })
        #expect(s.mostBlocked == nil && s.topApps.isEmpty)
    }

    @Test func streaksCountConsecutiveDaysAndSurviveAnUnfocusedToday() {
        // Yesterday and the two days before, a gap, then five days in a row.
        let sessions = [-1, -2, -3, -5, -6, -7, -8, -9].map { Self.entry($0, minutes: 25) }
        let s = stats(sessions)
        #expect(s.currentStreak == 3, "today has no session yet, which must not break the streak")
        #expect(s.longestStreak == 5)
        let withToday = stats(sessions + [Self.entry(0, minutes: 10)])
        #expect(withToday.currentStreak == 4)
    }

    @Test func aGapBreaksTheCurrentStreak() {
        #expect(stats([Self.entry(-2, minutes: 25)]).currentStreak == 0)
    }

    @Test func totalsLongestAndCompletion() {
        let s = stats([Self.entry(-1, minutes: 25), Self.entry(-1, minutes: 90, outcome: .endedEarly), Self.entry(-3, minutes: 45)])
        #expect(s.sessionCount == 3)
        #expect(s.completedCount == 2)
        #expect(s.totalFocused == 160 * 60)
        #expect(s.longestSession?.focused == 90 * minute)
    }

    @Test func mostBlockedQuitAndFocusedAddUpAcrossSessions() {
        let a = Self.entry(-1, minutes: 25, blocks: ["youtube.com": 3, "com.tinyspeck.slackmacgap": 2],
                           quits: ["com.tinyspeck.slackmacgap": 2], fg: ["com.apple.dt.Xcode": 1200, "com.apple.Safari": 300],
                           names: ["com.tinyspeck.slackmacgap": "Slack", "com.apple.dt.Xcode": "Xcode", "com.apple.Safari": "Safari",
                                   "youtube.com": "youtube.com"])
        let b = Self.entry(-2, minutes: 25, blocks: ["com.tinyspeck.slackmacgap": 2], quits: ["com.hnc.Discord": 1],
                           fg: ["com.apple.Safari": 1000], names: ["com.hnc.Discord": "Discord", "com.apple.Safari": "Safari"])
        let s = stats([a, b])
        #expect(s.mostBlocked == .init(key: "com.tinyspeck.slackmacgap", name: "Slack", value: 4))
        #expect(s.mostQuit == .init(key: "com.tinyspeck.slackmacgap", name: "Slack", value: 2))
        #expect(s.topApps.map(\.name) == ["Safari", "Xcode"])
        #expect(s.topApps.first?.value == 1300)
    }

    @Test func theGraphEndsWithThisWeekAndAddsUpEachDay() {
        let s = stats([Self.entry(0, minutes: 30), Self.entry(0, minutes: 20), Self.entry(-1, minutes: 10), Self.entry(-400, minutes: 60)])
        let lastWeek = s.weeks.last!
        #expect(Self.calendar.component(.weekday, from: lastWeek[0].date) == 2, "columns start on the calendar's first weekday")
        let today = lastWeek.first { Self.calendar.isDate($0.date, inSameDayAs: Self.now) }!
        #expect(today.focused == 50 * 60)
        #expect(lastWeek.filter(\.isFuture).count == 2, "Saturday and Sunday are still to come")
        #expect(s.focusedThisWeek == 60 * 60)
        #expect(s.weeks.flatMap { $0 }.allSatisfy { $0.focused == 0 || Self.calendar.dateComponents([.day], from: $0.date, to: Self.now).day! < 200 },
                "a session from last year falls off the six-month graph")
    }

    @Test(arguments: [(0.0, 0), (59.0, 0), (60.0, 1), (24 * 60.0, 1), (25 * 60.0, 2), (3599.0, 2), (3600.0, 3), (7200.0, 4)])
    func levels(_ seconds: Double, _ expected: Int) {
        #expect(FocusStats.level(for: seconds) == expected)
    }
}

@MainActor
struct HistoryFileTests {
    @Test func tooShortSessionsAreNotRecorded() {
        let h = Harness()
        h.engine.start(plan(25))
        h.clock.advance(30)
        h.engine.end()
        guard case .ended(let reason, let final)? = h.events.last else { Issue.record("no end"); return }
        #expect(SessionEntry(ended: final, outcome: reason) == nil)
    }

    @Test func theFileRoundTripsAndClears() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("focus-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let history = FocusHistory(url: url)
        history.append(StatsTests.entry(-1, minutes: 25))
        history.append(StatsTests.entry(-2, minutes: 45))
        #expect(FocusHistory(url: url).sessions.count == 2)
        history.clear()
        #expect(FocusHistory(url: url).sessions.isEmpty)
    }
}
