//
//  WidgetPolishTests.swift
//  NidusTests
//
//  What the large Nidus Today widget is given (focus spans and the top three
//  categories), and that widget.json still reads when those fields are
//  missing or malformed.
//

import Foundation
import Testing
@testable import Nidus

@Suite("Widget snapshot polish")
struct WidgetPolishTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        return calendar
    }()
    private var calendar: Calendar { Self.calendar }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))! }
    private var key: String { ActivityDayLog.key(for: day, calendar: calendar) }

    private func decode(_ json: String) throws -> WidgetSnapshot {
        try JSONDecoder().decode(WidgetSnapshot.self, from: Data(json.utf8))
    }

    // MARK: Decoding

    @Test func aSnapshotFromBeforeTheNewFieldsStillDecodes() throws {
        let snapshot = try decode("""
        {"version":1,"state":"focusing","goal":"Write","strict":true,"setups":[{"id":"a","name":"Deep","symbol":"brain"}],
         "today":{"day":"2026-03-10","work":600,"distracting":60,"other":30,
                  "bands":[{"startMinute":540,"endMinute":600,"kind":"work"}]}}
        """)
        #expect(snapshot.state == .focusing)
        #expect(snapshot.setups.count == 1)
        #expect(snapshot.today?.work == 600)
        #expect(snapshot.today?.bands.count == 1)
        #expect(snapshot.today?.focus == nil)
        #expect(snapshot.today?.top == nil)
    }

    @Test func garbageInTheNewFieldsIsNilAndKeepsTheRest() throws {
        let snapshot = try decode("""
        {"state":"idle","goal":"Keep","today":{"day":"2026-03-10","work":600,
         "bands":[{"startMinute":540,"endMinute":600,"kind":"work"}],
         "focus":"nope","top":[{"name":5,"minutes":"x"}]}}
        """)
        #expect(snapshot.goal == "Keep")
        #expect(snapshot.today?.work == 600)
        #expect(snapshot.today?.bands.count == 1)
        #expect(snapshot.today?.focus == nil)
        #expect(snapshot.today?.top == nil)
    }

    @Test func aBrokenTodayDoesNotTakeTheSessionWithIt() throws {
        let snapshot = try decode(#"{"state":"focusing","goal":"Keep","today":{"work":"many"}}"#)
        #expect(snapshot.state == .focusing)
        #expect(snapshot.goal == "Keep")
        #expect(snapshot.today == nil)
    }

    @Test func theNewFieldsRoundTrip() throws {
        var today = WidgetToday(day: "2026-03-10", work: 60)
        today.focus = [.init(startMinute: 10, endMinute: 40)]
        today.top = [.init(name: "Work", minutes: 1, tint: -2)]
        let data = try JSONEncoder().encode(WidgetSnapshot(today: today))
        #expect(try JSONDecoder().decode(WidgetSnapshot.self, from: data).today == today)
    }

    // MARK: Building

    private var categorizer: ActivityCategorizer {
        var work = FocusCategory.workSeed
        work.apps = [BlockedApp(bundleID: "work.app", name: "Work")]
        var social = FocusCategory.workSeed
        social.role = .distracting
        social.id = "social"
        social.name = "Social"
        social.color = 3
        social.apps = [BlockedApp(bundleID: "social.app", name: "Social")]
        var news = social
        news.id = "news"
        news.name = "News"
        news.color = 5
        news.apps = [BlockedApp(bundleID: "news.app", name: "News")]
        var video = social
        video.id = "video"
        video.name = "Video"
        video.color = 1
        video.apps = [BlockedApp(bundleID: "video.app", name: "Video")]
        return ActivityCategorizer(categories: [social, news, video], work: work)
    }

    private func stretch(_ app: String, from start: Double, to end: Double) -> FocusActivitySegment {
        FocusActivitySegment(start: day.addingTimeInterval(start * 60), end: day.addingTimeInterval(end * 60), appID: app, appName: app)
    }

    private func session(from start: Double, to end: Double) -> SessionEntry {
        SessionEntry(start: day.addingTimeInterval(start * 60), end: day.addingTimeInterval(end * 60),
                     focused: (end - start) * 60, planned: nil, outcome: .completed)
    }

    @Test func theTopThreeAreBiggestFirstWithTheirTints() throws {
        var log = ActivityDayLog(day: key)
        log.stretches = [
            stretch("news.app", from: 600, to: 640),    // 40
            stretch("work.app", from: 540, to: 600),    // 60
            stretch("social.app", from: 650, to: 665),  // 15
            stretch("video.app", from: 670, to: 675),   // 5
            stretch("other.app", from: 700, to: 730),   // 30, uncategorized
        ]
        let today = ActivityTodaySummary.build(log: log, categorizer: categorizer, calendar: calendar)
        let top = try #require(today.top)
        #expect(top.map(\.name) == ["Work", "News", "Uncategorized"])
        #expect(top.map(\.minutes) == [60, 40, 30])
        #expect(top.map(\.tint) == [ActivityTint.work, 5, ActivityTint.quiet])
    }

    @Test func aTieIsBrokenByName() {
        var log = ActivityDayLog(day: key)
        log.stretches = [stretch("news.app", from: 600, to: 620), stretch("social.app", from: 630, to: 650)]
        let today = ActivityTodaySummary.build(log: log, categorizer: categorizer, calendar: calendar)
        #expect(today.top?.map(\.name) == ["News", "Social"])
    }

    @Test func focusSpansAreTodaysSessionsInMinutesJoinedWhereTheyTouch() {
        var log = ActivityDayLog(day: key)
        log.stretches = [stretch("work.app", from: 540, to: 600)]
        let sessions = [
            session(from: 780, to: 810),
            session(from: 540, to: 570),
            session(from: 570, to: 590),
            session(from: -30, to: 20),       // began yesterday: only today's part
            session(from: -300, to: -240),    // yesterday
        ]
        let today = ActivityTodaySummary.build(log: log, categorizer: categorizer, sessions: sessions, calendar: calendar)
        #expect(today.focus == [.init(startMinute: 0, endMinute: 20), .init(startMinute: 540, endMinute: 590),
                                .init(startMinute: 780, endMinute: 810)])
    }

    @Test func aDayWithNoSessionsHasAnEmptyFocusAndNoTopCategories() {
        var log = ActivityDayLog(day: key)
        log.stretches = [stretch("work.app", from: 540, to: 600)]
        let today = ActivityTodaySummary.build(log: log, categorizer: categorizer, calendar: calendar)
        #expect(today.focus == [])
        #expect(today.top?.count == 1)
    }

    @Test func theBandsAndTotalsAreWhatTheyWereBefore() {
        var log = ActivityDayLog(day: key)
        log.stretches = [stretch("work.app", from: 540, to: 600), stretch("social.app", from: 600, to: 630)]
        let plain = ActivityTodaySummary.build(log: log, categorizer: categorizer, calendar: calendar)
        let withSessions = ActivityTodaySummary.build(log: log, categorizer: categorizer, sessions: [session(from: 540, to: 570)], calendar: calendar)
        #expect(plain.bands == withSessions.bands)
        #expect(plain.work == 3600)
        #expect(plain.distracting == 1800)
    }
}
