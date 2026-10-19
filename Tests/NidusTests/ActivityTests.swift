import Foundation
import Testing
@testable import Nidus

@MainActor
struct ActivityTests {
    @Test func aggregatesWithoutExceedingFocusedTime() {
        let h = Harness()
        h.engine.start(plan(1))
        h.engine.initializeActivity()
        #expect(h.engine.session?.activity == [])
        h.clock.advance(3)
        h.engine.recordActivity(appID: "com.microsoft.Word", appName: "Word", title: "Draft", seconds: 2)
        h.engine.recordActivity(appID: "com.microsoft.Word", appName: "Word", title: "Draft", seconds: 2)
        #expect(h.engine.session?.activity?.count == 1)
        #expect(h.engine.session?.activity?.first?.seconds == 3)
        #expect(h.engine.session?.foreground["com.microsoft.Word"] == 3)
        #expect(h.engine.session?.activitySegments?.count == 1)
        #expect(h.engine.session?.activitySegments?.first?.seconds == 2,
                "An overlapping call at the same clock time cannot invent another interval")

        h.clock.advance(58)
        h.engine.recordActivity(appID: "com.microsoft.Word", appName: "Word", title: "Draft", seconds: 58)
        #expect(h.engine.session?.activity?.first?.seconds == 60)
        h.engine.tick()
        #expect(h.engine.session == nil)
    }

    @Test func timelineCountsOnlyObservedAdjacentContextChanges() {
        let h = Harness()
        h.engine.start(plan(2))
        h.engine.initializeActivity()
        h.clock.advance(1)
        h.engine.recordActivity(appID: "app.word", appName: "Word", title: "A", seconds: 1)
        h.clock.advance(1)
        h.engine.recordActivity(appID: "app.word", appName: "Word", title: "A", seconds: 1)
        h.clock.advance(1)
        h.engine.recordActivity(appID: "app.word", appName: "Word", title: "B", seconds: 1)
        var segments = h.engine.session?.activitySegments ?? []
        #expect(segments.count == 2)
        #expect(ActivityTimeline.switchCount(segments) == 1)
        #expect(ActivityTimeline.longestStretch(segments) == 2)

        h.engine.pause()
        h.engine.resume()
        h.clock.advance(1)
        h.engine.recordActivity(appID: "app.word", appName: "Word", title: "C", seconds: 1)
        segments = h.engine.session?.activitySegments ?? []
        #expect(ActivityTimeline.switchCount(segments) == 1,
                "A pause breaks the observed sequence even without wall-clock delay")
        h.clock.advance(10)
        h.engine.recordActivity(appID: "app.browser", appName: "Browser", seconds: 1)
        segments = h.engine.session?.activitySegments ?? []
        #expect(ActivityTimeline.switchCount(segments) == 1,
                "An unsampled gap cannot prove a direct switch")
        #expect(ActivityTimeline.longestStretch(segments) == 2)
    }

    @Test func timelineDoesNotCountProbeEnrichmentAsDocumentSwitch() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let a = FocusActivitySegment(start: start, end: start.addingTimeInterval(1),
                                     appID: "app.browser", appName: "Browser")
        let b = FocusActivitySegment(start: a.end, end: a.end.addingTimeInterval(1),
                                     appID: "app.browser", appName: "Browser", title: "Draft")
        #expect(ActivityTimeline.switchCount([a, b]) == 0)
        #expect(ActivityTimeline.longestStretch([a, b]) == 1)
        var enriched = b
        enriched.site = "Google Docs"
        #expect(ActivityTimeline.switchCount([a, enriched]) == 0)
        #expect(ActivityTimeline.safeSite("https://docs.google.com/private") == nil)
        #expect(ActivityTimeline.safeSite("private.example") == nil)
    }

    @Test func switchCountIncludesShortActivationEdgeButNotSkippedObservation() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let word = FocusActivitySegment(start: start, end: start.addingTimeInterval(1),
                                        appID: "app.word", appName: "Word")
        let browser = FocusActivitySegment(start: word.end.addingTimeInterval(0.4),
                                           end: word.end.addingTimeInterval(1.4),
                                           appID: "app.browser", appName: "Browser")
        #expect(ActivityTimeline.switchCount([word, browser]) == 1)
        #expect(ActivityTimeline.longestStretch([word, browser]) == 1)
        var afterSkippedTick = browser
        afterSkippedTick.continuity = 1
        #expect(ActivityTimeline.switchCount([word, afterSkippedTick]) == 0)
    }

    @Test func explicitSampleTimestampKeepsConsecutiveTicksContinuous() {
        let clock = TestClock()
        let engine = SessionEngine(store: nil, now: { clock.now.addingTimeInterval(0.005) })
        engine.start(plan(2))
        engine.initializeActivity()
        clock.advance(2)
        engine.recordActivity(appID: "app.word", appName: "Word", seconds: 1, sampledAt: clock.now)
        clock.advance(1)
        engine.recordActivity(appID: "app.word", appName: "Word", seconds: 1, sampledAt: clock.now)
        #expect(engine.session?.activitySegments?.count == 1)
        #expect(engine.session?.activitySegments?.first?.seconds == 2)
    }

    @Test func excludingAnIntervalCannotCreateASwitchAcrossIt() {
        let h = Harness()
        h.engine.start(plan(2))
        h.engine.initializeActivity()
        for appID in ["app.a", "app.hidden", "app.b"] {
            h.clock.advance(1)
            h.engine.recordActivity(appID: appID, appName: appID, seconds: 1)
        }
        #expect(ActivityTimeline.switchCount(h.engine.session?.activitySegments ?? []) == 2)
        h.engine.checkpoint()
        let restored = SessionEngine(store: h.store, now: { h.clock.now })
        restored.restore(excludedApps: ["app.hidden"])
        let retained = restored.session?.activitySegments ?? []
        #expect(retained.map(\.appID) == ["app.a", "app.b"])
        #expect(ActivityTimeline.switchCount(retained) == 0,
                "A deleted observation cannot make its neighbors a direct switch")
        h.clock.advance(1)
        restored.recordActivity(appID: "app.c", appName: "C", seconds: 1)
        #expect(ActivityTimeline.switchCount(restored.session?.activitySegments ?? []) == 0)
    }

    @Test func removingTitlesPreservesKnownDocumentBoundariesWithoutNames() {
        let h = Harness()
        h.engine.start(plan(2))
        h.engine.initializeActivity()
        h.clock.advance(1)
        h.engine.recordActivity(appID: "app.word", appName: "Word", title: "Private A", seconds: 1)
        h.clock.advance(1)
        h.engine.recordActivity(appID: "app.word", appName: "Word", title: "Private B", seconds: 1)
        #expect(ActivityTimeline.switchCount(h.engine.session?.activitySegments ?? []) == 1)
        h.engine.removeCurrentActivityTitles()
        let redacted = h.engine.session?.activitySegments ?? []
        #expect(redacted.allSatisfy { $0.title == nil })
        #expect(ActivityTimeline.switchCount(redacted) == 0)
        #expect(ActivityTimeline.longestStretch(redacted) == 1,
                "Removing names cannot invent a continuous document stretch")
    }

    @Test func restoreRedactsTimelineEvenIfAggregateRowsAreMissing() {
        let h = Harness()
        h.engine.start(plan(2))
        h.clock.advance(1)
        h.engine.recordActivity(appID: "app.word", appName: "Word", title: "Private A", seconds: 1)
        h.engine.checkpoint()
        var record = h.store.record!
        record.session?.activity = nil
        h.store.record = record
        let restored = SessionEngine(store: h.store, now: { h.clock.now })
        restored.restore(allowTitles: false)
        #expect(restored.session?.activitySegments?.first?.title == nil)
    }

    @Test func timelineIsBoundedAndPrivacyChoicesApplyOnRestore() {
        let h = Harness()
        h.engine.start(plan(20))
        for index in 0..<520 {
            h.clock.advance(1)
            h.engine.recordActivity(appID: index.isMultiple(of: 2) ? "app.a" : "app.b",
                                    appName: "App", title: "Private", seconds: 1)
        }
        #expect(h.engine.session?.activitySegments?.count == ActivityTimeline.limit)
        #expect(h.engine.session?.activityTimelineTruncated == true)
        h.engine.checkpoint()
        let restored = SessionEngine(store: h.store, now: { h.clock.now })
        restored.restore(allowActivity: true, allowTitles: false, excludedApps: ["app.a"])
        #expect(restored.session?.activitySegments?.allSatisfy { $0.appID == "app.b" && $0.title == nil } == true)
        restored.clearCurrentActivity()
        #expect(restored.session?.activitySegments == nil)
        #expect(h.store.record?.session?.activitySegments == nil)
    }

    @Test func pausedAndClearedSessionsDoNotRetainNames() {
        let h = Harness()
        h.engine.start(plan(2))
        h.clock.advance(2)
        h.engine.recordActivity(appID: "com.microsoft.Word", appName: "Word", title: "Private draft", seconds: 2)
        h.engine.pause()
        h.clock.advance(3)
        h.engine.recordActivity(appID: "com.microsoft.Word", appName: "Word", title: "Private draft", seconds: 3)
        #expect(h.engine.session?.activity?.first?.seconds == 2)
        h.engine.removeCurrentActivityTitles()
        #expect(h.engine.session?.activity?.first?.title == nil)
        #expect(h.engine.session?.activitySegments?.first?.title == nil)
        h.engine.excludeCurrentActivity(appIDs: ["com.microsoft.Word"])
        #expect(h.engine.session?.activity == [])
        #expect(h.engine.session?.activitySegments == [])
        #expect(h.engine.session?.foreground["com.microsoft.Word"] == nil)
        h.engine.clearCurrentActivity()
        #expect(h.engine.session?.activity == nil)
        #expect(h.store.record?.session?.activity == nil)
    }

    @Test func oldEntryAndStateDecodeWithoutActivity() throws {
        let h = Harness()
        h.engine.start(plan(2))
        let stateData = try JSONEncoder().encode(h.engine.session!)
        let oldState = try JSONDecoder().decode(SessionState.self, from: stateData)
        #expect(oldState.activity == nil)
        #expect(oldState.activitySegments == nil)

        let entry = SessionEntry(start: h.clock.now, end: h.clock.now.addingTimeInterval(60), focused: 60,
                                 planned: 120, outcome: .completed, foreground: ["com.microsoft.Word": 30],
                                 names: ["com.microsoft.Word": "Word"])
        let oldEntry = try JSONDecoder().decode(SessionEntry.self, from: JSONEncoder().encode(entry))
        #expect(oldEntry.activity == nil)
        #expect(oldEntry.activitySegments == nil)
        #expect(oldEntry.foreground["com.microsoft.Word"] == 30)
    }

    @Test func restoreAppliesPrivacyBeforeAnExpiredSessionEntersHistory() {
        let h = Harness()
        h.engine.start(plan(1))
        h.clock.advance(2)
        h.engine.recordActivity(appID: "com.microsoft.Word", appName: "Word", title: "Private draft", seconds: 2)
        h.engine.checkpoint()
        h.clock.advance(61)

        let restored = SessionEngine(store: h.store, now: { h.clock.now })
        var finished: SessionState?
        restored.onEvent = { event in
            if case .ended(_, let state) = event { finished = state }
        }
        restored.restore(allowActivity: false, allowTitles: false)
        #expect(finished?.activity == nil)
        #expect(finished?.activitySegments == nil)
        #expect(finished?.foreground.isEmpty == true)
        #expect(finished?.names["com.microsoft.Word"] == nil)
    }

    @Test func restoreRemovesDisabledTitlesAndExcludedApps() {
        let h = Harness()
        h.engine.start(plan(2))
        h.clock.advance(3)
        h.engine.recordActivity(appID: "com.microsoft.Word", appName: "Word", title: "Private draft", seconds: 2)
        h.engine.recordActivity(appID: "app.exclude", appName: "Excluded", seconds: 1)
        h.engine.checkpoint()

        let restored = SessionEngine(store: h.store, now: { h.clock.now })
        restored.restore(allowActivity: true, allowTitles: false, excludedApps: ["app.exclude"])
        #expect(restored.session?.activity?.count == 1)
        #expect(restored.session?.activity?.first?.title == nil)
        #expect(restored.session?.foreground["app.exclude"] == nil)
    }

    @Test func restoreFiltersBeforeFinishingWithNamesAllowed() {
        let h = Harness()
        h.engine.start(plan(1))
        h.clock.advance(3)
        h.engine.recordActivity(appID: "com.microsoft.Word", appName: "Word", title: "Private draft", seconds: 2)
        h.engine.recordActivity(appID: "app.exclude", appName: "Excluded", seconds: 1)
        h.engine.checkpoint()
        h.clock.advance(61)

        let restored = SessionEngine(store: h.store, now: { h.clock.now })
        var finished: SessionState?
        restored.onEvent = { event in
            if case .ended(_, let state) = event { finished = state }
        }
        restored.restore(allowActivity: true, allowTitles: false, excludedApps: ["app.exclude"])
        #expect(finished?.activity?.count == 1)
        #expect(finished?.activity?.first?.title == nil)
        #expect(finished?.foreground["app.exclude"] == nil)
    }

    @Test func recognizedSitesStayNarrowAndTitlesStayShort() {
        #expect(ActivityProbe.service(for: "https://docs.google.com/document/d/abc/edit?secret=yes") == "Google Docs")
        #expect(ActivityProbe.service(for: "https://docs.google.com/spreadsheets/d/abc") == nil)
        #expect(ActivityProbe.service(for: "https://evil.example/claude.ai") == nil)
        #expect(ActivityProbe.service(for: "https://claude.ai/chat/abc") == "Claude")
        #expect(ActivityProbe.cleanTitle("  My  Draft\nTwo ") == "My Draft Two")
        #expect(ActivityProbe.cleanTitle("https://docs.google.com/document/d/private") == nil)
        #expect(ActivityProbe.cleanTitle(String(repeating: "x", count: 200))?.count == 160)
        #expect(ActivityProbe.usefulTitle("Claude Science") == nil)
        #expect(ActivityProbe.usefulTitle("Microsoft Word") == nil)
        #expect(ActivityProbe.usefulTitle("Settings") == nil)
        #expect(ActivityProbe.usefulTitle("A real draft") == "A real draft")
    }

    @Test func detailExportEscapesFormulasAndFallsBackOnlyForLegacy() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let legacy = SessionEntry(start: start, end: start.addingTimeInterval(60), focused: 60,
                                  planned: 60, outcome: .completed, goal: "=SUM(1,2)",
                                  foreground: ["app.old": 30], names: ["app.old": "Old App"])
        let tracked = SessionEntry(start: start, end: start.addingTimeInterval(60), focused: 60,
                                   planned: 60, outcome: .completed, foreground: ["app.new": 20],
                                   activity: [FocusActivity(appID: "app.new", appName: "New App", site: "Google Docs",
                                                            title: "+Draft, one", seconds: 20)])
        let empty = SessionEntry(start: start, end: start.addingTimeInterval(60), focused: 60,
                                 planned: 60, outcome: .completed, foreground: ["app.empty": 10], activity: [])
        let csv = ActivityExport.csv(sessions: [legacy, tracked, empty])
        #expect(csv.contains("Old App"))
        #expect(csv.contains("New App"))
        #expect(!csv.contains("app.empty"))
        #expect(csv.contains("'=SUM(1,2)"))
        #expect(csv.contains("'+Draft, one"))
        #expect(csv.components(separatedBy: "\r\n").count == 4)
    }
}

@MainActor
struct ActivityTitleRemovalTests {
    @Test func removingNamesFromHistoryKeepsTimesAndSwitches() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-titles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var named = SessionEntry(start: start, end: start.addingTimeInterval(600), focused: 600, planned: 600, outcome: .completed)
        named.activity = [FocusActivity(appID: "com.microsoft.Word", appName: "Word", title: "Aims", seconds: 300),
                          FocusActivity(appID: "com.microsoft.Word", appName: "Word", title: "Budget", seconds: 200)]
        named.activitySegments = [
            FocusActivitySegment(start: start, end: start.addingTimeInterval(300), appID: "com.microsoft.Word", appName: "Word", title: "Aims"),
            FocusActivitySegment(start: start.addingTimeInterval(300), end: start.addingTimeInterval(500), appID: "com.microsoft.Word", appName: "Word", title: "Budget"),
        ]
        let plain = SessionEntry(start: start, end: start.addingTimeInterval(120), focused: 120, planned: nil, outcome: .completed)
        let history = FocusHistory(url: url)
        history.append(named)
        history.append(plain)
        #expect(history.hasActivityTitles)

        #expect(history.removeActivityTitles() == 1)
        let reread = FocusHistory(url: url)
        let entry = try #require(reread.sessions.first { $0.id == named.id })
        let rows = try #require(entry.activity)
        #expect(rows.count == 1 && rows[0].appID == "com.microsoft.Word" && rows[0].title == nil && rows[0].seconds == 500,
                "the two Word rows are one now, with all their time")
        let segments = try #require(entry.activitySegments)
        #expect(segments.allSatisfy { $0.title == nil })
        #expect(segments[0].continuity != segments[1].continuity, "the switch between documents is still a switch")
        #expect(!reread.hasActivityTitles)
        #expect(reread.sessions.first { $0.id == plain.id } == plain, "a session without names is untouched")
        #expect(history.removeActivityTitles() == 0, "nothing left: nothing written")
    }
}
