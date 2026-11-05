import AppKit
import Foundation
import Testing
@testable import Nidus

/// The Mac, as the recorder sees it. A probe waits for `answer` unless an
/// `autoAnswer` is set, so tests can hold one open across other events.
@MainActor
private final class FakeHost: ActivityRecorderHost {
    var front: ActivityFrontApp?
    var idle: TimeInterval = 0
    var autoAnswer: ((ActivityFrontApp) -> ActivityDetail?)?
    private(set) var probes = 0
    private var waiting: [@MainActor (ActivityDetail?) -> Void] = []
    private(set) var armed: TimeInterval?
    private var fire: (@MainActor () -> Void)?

    func frontApp() -> ActivityFrontApp? { front }
    func secondsSinceInput() -> TimeInterval { idle }
    func probe(_ app: ActivityFrontApp, titles: Bool, completion: @escaping @MainActor (ActivityDetail?) -> Void) {
        probes += 1
        if let autoAnswer { completion(autoAnswer(app)) } else { waiting.append(completion) }
    }
    func answer(_ detail: ActivityDetail?) { waiting.removeFirst()(detail) }
    func arm(after seconds: TimeInterval?, fire: @escaping @MainActor () -> Void) {
        armed = seconds
        self.fire = seconds == nil ? nil : fire
    }
    func wake() { fire?() }
}

@MainActor
private final class Rig {
    static let word = ActivityFrontApp(id: "com.microsoft.Word", name: "Word", pid: 11)
    static let mail = ActivityFrontApp(id: "com.apple.mail", name: "Mail", pid: 12)
    static let safari = ActivityFrontApp(id: "com.apple.Safari", name: "Safari", pid: 13)
    static let chrome = ActivityFrontApp(id: "com.google.Chrome", name: "Chrome", pid: 14)
    static let preview = ActivityFrontApp(id: ActivityProbe.previewID, name: "Preview", pid: 15)

    let clock = TestClock()
    let host = FakeHost()
    let directory: URL
    let store: ActivityDayStore
    var calendar = Calendar(identifier: .gregorian)
    let recorder: ActivityRecorder

    /// 09:00 on an ordinary day in UTC.
    init(settings: ActivityRecorderSettings = ActivityRecorderSettings(enabled: true), at start: String = "2026-11-04T09:00:00Z") {
        calendar.timeZone = TimeZone(identifier: "UTC")!
        clock.now = ISO8601DateFormatter().date(from: start)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-recorder-\(UUID().uuidString)")
        store = ActivityDayStore(directory: directory)
        let clock = clock
        recorder = ActivityRecorder(store: store, host: host, now: { clock.now }, calendar: calendar)
        recorder.apply(settings)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func start(_ app: ActivityFrontApp? = Rig.word) {
        host.front = app
        recorder.start()
    }
    func switchTo(_ app: ActivityFrontApp?) {
        host.front = app
        recorder.frontAppDidChange()
    }
    /// Time passes with someone at the keyboard, and the recorder's timer runs.
    func work(_ seconds: TimeInterval) {
        clock.advance(seconds)
        host.wake()
    }
    /// Time passes with nobody there; the timer fires once, at the end.
    func leave(_ seconds: TimeInterval) {
        clock.advance(seconds)
        host.idle += seconds
        host.wake()
    }
    var stretches: [FocusActivitySegment] { recorder.today().stretches }
    var total: TimeInterval { recorder.today().seconds }
    func day(_ key: String) -> ActivityDayLog? { store.flush(); return store.load(day: key) }
}

@MainActor
struct ActivityRecorderTests {
    @Test func recordsNothingUntilTurnedOn() {
        let rig = Rig(settings: ActivityRecorderSettings(enabled: false))
        rig.start()
        rig.clock.advance(600)
        rig.recorder.frontAppDidChange()
        #expect(rig.recorder.today().isEmpty)
        #expect(rig.host.armed == nil, "Off means no timer at all")
        rig.recorder.stop()
        #expect(!FileManager.default.fileExists(atPath: rig.directory.path), "and no files")
    }

    @Test func aStretchEndsWhenTheAppChanges() {
        let rig = Rig()
        rig.start(Rig.word)
        rig.clock.advance(60)
        rig.switchTo(Rig.mail)
        rig.clock.advance(30)
        rig.switchTo(Rig.word)
        rig.clock.advance(10)
        rig.recorder.stop()
        let log = rig.day("2026-11-04")!
        #expect(log.stretches.map(\.appName) == ["Word", "Mail", "Word"])
        #expect(log.stretches.map(\.seconds) == [60, 30, 10])
        #expect(log.totals.first { $0.appName == "Word" }?.seconds == 70)
        #expect(ActivityTimeline.switchCount(log.stretches) == 2, "Switches with no time missing stay adjacent")
    }

    @Test func nothingWakesAnUnchangingAppMoreThanTheIdleCheck() {
        let rig = Rig()
        rig.start(Rig.word)
        #expect(rig.host.armed == 120, "The save comes before the idle cut-off")
        #expect(rig.host.probes == 0, "Word with names off has nothing to read")
        rig.host.idle = 200
        rig.work(120)
        #expect(rig.host.armed == 100, "Then the exact moment idle could begin")
    }

    @Test func idleCutsAtTheLastInputNotAtTheCutoff() {
        let rig = Rig()
        rig.start(Rig.word)
        rig.work(100)
        rig.leave(300)
        #expect(rig.recorder.isIdle)
        #expect(rig.total == 100, "Credit stops at the last input")
        #expect(rig.host.armed == ActivityRecorder.idlePollInterval)
    }

    @Test func aMinuteWithoutInputUnderTheCutoffStillCounts() {
        let rig = Rig()
        rig.start(Rig.word)
        rig.leave(240)
        #expect(!rig.recorder.isIdle, "Reading a long legend isn't idle")
        rig.host.idle = 0
        rig.work(60)
        #expect(rig.total == 300)
    }

    @Test func comingBackStartsANewStretchAtTheLastInput() {
        let rig = Rig()
        rig.start(Rig.word)
        rig.work(100)
        rig.leave(3600)
        rig.clock.advance(10)
        rig.host.idle = 4
        rig.host.wake()
        #expect(!rig.recorder.isIdle)
        rig.clock.advance(4)
        rig.host.idle = 0
        rig.recorder.frontAppDidChange()
        let stretches = rig.stretches
        #expect(stretches.count == 2)
        #expect(stretches[1].seconds == 8, "From the input that ended the idle spell")
        #expect(!ActivityTimeline.touches(stretches[0], stretches[1]))
    }

    @Test func idleCutoffIsAdjustable() {
        var settings = ActivityRecorderSettings(enabled: true)
        settings.idleCutoff = 60
        let rig = Rig(settings: settings)
        rig.start(Rig.word)
        rig.leave(60)
        #expect(rig.recorder.isIdle)
    }

    @Test func aRunningSessionIsNeverCutByIdle() {
        let rig = Rig()
        rig.recorder.setFocusRunning(true)
        rig.start(Rig.word)
        rig.leave(1800)
        #expect(!rig.recorder.isIdle)
        #expect(rig.total == 1800, "Inside a session, silence counts as reading")

        rig.clock.advance(60)
        rig.host.idle += 60
        rig.recorder.setFocusRunning(false)
        #expect(rig.recorder.isIdle, "The ordinary rule is back the moment it stops")
        #expect(rig.total == 1860, "and the session's own silent minutes stay credited")
    }

    @Test func lockAndSleepEndTheStretchAndStopTheTimer() {
        let rig = Rig()
        rig.start(Rig.word)
        rig.clock.advance(50)
        rig.recorder.screenDidLock()
        #expect(rig.total == 50)
        #expect(rig.host.armed == nil)
        rig.clock.advance(1000)
        rig.recorder.screenDidUnlock()
        rig.clock.advance(20)
        rig.recorder.systemWillSleep()
        #expect(rig.total == 70)
        #expect(rig.host.armed == nil)
        rig.clock.advance(1000)
        rig.recorder.systemDidWake()
        rig.clock.advance(5)
        #expect(rig.total == 75)
        #expect(rig.stretches.count == 3)
    }

    @Test func lockingAfterGoingIdleCreditsOnlyUpToTheLastInput() {
        let rig = Rig()
        rig.start(Rig.word)
        rig.clock.advance(400)
        rig.host.idle = 350
        rig.recorder.screenDidLock()
        #expect(rig.total == 50)
    }

    @Test func wakingStillLockedStaysAway() {
        let rig = Rig()
        rig.start(Rig.word)
        rig.recorder.screenDidLock()
        rig.recorder.systemWillSleep()
        rig.recorder.systemDidWake()
        rig.clock.advance(100)
        #expect(rig.total == 0)
        #expect(rig.host.armed == nil)
    }

    @Test func pauseStopsRecordingUntilItEnds() {
        let rig = Rig()
        rig.start(Rig.word)
        rig.clock.advance(30)
        var settings = rig.recorder.settings
        settings.pausedUntil = rig.clock.now.addingTimeInterval(3600)
        rig.recorder.apply(settings)
        #expect(!rig.recorder.isRecording)
        #expect(rig.total == 30)
        #expect(rig.host.armed == 3600, "One timer, for the end of the pause")
        rig.clock.advance(3600)
        rig.host.wake()
        #expect(rig.recorder.isRecording)
        rig.clock.advance(5)
        #expect(rig.total == 35)
    }

    @Test func excludedAndBackgroundAppsAreNotRecorded() {
        var settings = ActivityRecorderSettings(enabled: true)
        settings.excluded = [Rig.mail.id]
        let rig = Rig(settings: settings)
        rig.start(Rig.mail)
        rig.clock.advance(60)
        rig.switchTo(ActivityFrontApp(id: "com.example.agent", name: "Agent", pid: 20, isRegular: false))
        rig.clock.advance(60)
        rig.switchTo(ActivityFrontApp(id: "com.apple.loginwindow", name: "loginwindow", pid: 21))
        rig.clock.advance(60)
        rig.switchTo(Rig.word)
        rig.clock.advance(60)
        #expect(rig.stretches.map(\.appID) == [Rig.word.id])
    }

    @Test func passingThroughAnAppLeavesNoStretch() {
        let rig = Rig()
        rig.start(Rig.word)
        rig.clock.advance(10)
        rig.switchTo(Rig.mail)
        rig.clock.advance(0.3)
        rig.switchTo(Rig.word)
        rig.clock.advance(10)
        #expect(rig.stretches.map(\.appID) == [Rig.word.id, Rig.word.id])
    }

    // MARK: Midnight

    @Test func midnightSplitsTheStretchIntoTwoFiles() {
        let rig = Rig(at: "2026-11-04T23:59:00Z")
        rig.start(Rig.word)
        #expect(rig.host.armed == 60, "The next wake is the day's end at the latest")
        rig.clock.advance(120)
        rig.host.wake()
        rig.clock.advance(30)
        rig.recorder.stop()
        #expect(rig.day("2026-11-04")?.seconds == 60)
        #expect(rig.day("2026-11-05")?.seconds == 90)
    }

    @Test func wakingDaysLaterFilesTheOldDayAndStartsAFreshOne() {
        let rig = Rig(at: "2026-11-04T23:00:00Z")
        rig.start(Rig.word)
        rig.clock.advance(600)
        rig.recorder.systemWillSleep()
        rig.clock.advance(3 * 86_400)
        rig.recorder.systemDidWake()
        rig.clock.advance(20)
        rig.recorder.stop()
        #expect(rig.day("2026-11-04")?.seconds == 600)
        #expect(rig.day("2026-11-07")?.seconds == 20)
        #expect(rig.day("2026-11-05") == nil)
    }

    @Test func aStretchCutByIdleBeforeMidnightIsNotCreditedPastTheLastInput() {
        let rig = Rig(at: "2026-11-04T23:50:00Z")
        rig.start(Rig.word)
        rig.clock.advance(60)
        rig.leave(720)
        rig.recorder.stop()
        #expect(rig.day("2026-11-04")?.seconds == 60)
        #expect(rig.day("2026-11-05") == nil)
    }

    @Test func aRelaunchAddsToTodaysFile() {
        let first = Rig()
        first.start(Rig.word)
        first.clock.advance(100)
        first.recorder.stop()

        let second = ActivityRecorder(store: first.store, host: first.host, now: { first.clock.now }, calendar: first.calendar)
        second.apply(ActivityRecorderSettings(enabled: true))
        second.start()
        first.clock.advance(50)
        #expect(second.today().seconds == 150)
        #expect(second.today().stretches.count == 2)
        #expect(!ActivityTimeline.touches(second.today().stretches[0], second.today().stretches[1]))
    }

    @Test func aPeriodicSaveKeepsTheOpenStretchWithoutDoubleCounting() {
        let rig = Rig()
        rig.start(Rig.word)
        rig.work(120)
        #expect(rig.day("2026-11-04")?.seconds == 120, "A crash now would lose nothing before this")
        rig.work(120)
        rig.recorder.stop()
        #expect(rig.day("2026-11-04")?.seconds == 240)
        #expect(rig.day("2026-11-04")?.stretches.count == 1)
    }

    @Test func settingTheClockBackCannotMakeANegativeStretch() {
        let rig = Rig()
        rig.start(Rig.word)
        rig.work(60)
        rig.clock.advance(-3600)
        rig.recorder.clockDidChange()
        rig.clock.advance(10)
        #expect(rig.stretches.allSatisfy { $0.end > $0.start })
        #expect(rig.total == 70)
    }

    // MARK: Pages

    @Test func aPageKeepsItsAddressButCountsUnderItsDomain() {
        let rig = Rig()
        rig.start(Rig.chrome)
        rig.host.answer(ActivityDetail(site: nil, title: "A paper", domain: "nature.com", url: "https://www.nature.com/articles/a?x=1"))
        rig.clock.advance(4)
        #expect(rig.stretches.map(\.site) == ["nature.com"])
        #expect(rig.stretches.first?.url == "https://www.nature.com/articles/a?x=1")
    }

    @Test func aBrowserLeftBeforeItsFirstReadIsStillTimeInThatBrowser() {
        let rig = Rig()
        rig.start(Rig.safari)
        rig.clock.advance(2)
        rig.switchTo(Rig.word)
        rig.clock.advance(3)
        #expect(rig.stretches.map(\.appID) == [Rig.safari.id, Rig.word.id])
        #expect(rig.stretches.first?.site == nil)
    }

    @Test func excludingAnAppKeepsItsSavedTime() {
        let rig = Rig()
        rig.start(Rig.mail)
        rig.clock.advance(10)
        var settings = rig.recorder.settings
        settings.excluded = [Rig.mail.id]
        rig.recorder.apply(settings)
        rig.clock.advance(5)
        #expect(rig.stretches.map(\.appID).contains(Rig.mail.id), "Hidden by the views, and back if it is let in again")
    }

    private func page(_ domain: String, title: String? = nil) -> ActivityDetail {
        ActivityDetail(site: nil, title: title, domain: domain)
    }

    @Test func aFirstReadNamesTheStretchFromItsStart() {
        let rig = Rig()
        rig.start(Rig.safari)
        rig.clock.advance(1)
        rig.host.answer(page("nature.com"))
        rig.clock.advance(1)
        #expect(rig.stretches.map(\.site) == ["nature.com"])
        #expect(rig.stretches.first?.seconds == 2)
    }

    @Test func aDifferentSiteClosesTheStretchAndNamesAreOptIn() {
        let rig = Rig()
        rig.start(Rig.chrome)
        rig.host.answer(page("nature.com", title: "A paper"))
        rig.work(4)
        rig.host.answer(page("nih.gov", title: "Another"))
        rig.clock.advance(4)
        #expect(rig.stretches.map(\.site) == ["nature.com", "nih.gov"])
        #expect(rig.stretches.allSatisfy { $0.title == nil }, "Names stay out with the opt-in off")
    }

    @Test func probesRunEveryFourSecondsOnlyWhileABrowserIsInFront() {
        let rig = Rig()
        rig.host.autoAnswer = { _ in ActivityDetail(site: nil, title: nil, domain: "nature.com") }
        rig.start(Rig.safari)
        #expect(rig.host.probes == 1)
        #expect(rig.host.armed == 4)
        rig.work(2)
        #expect(rig.host.probes == 1, "Never sooner than the interval")
        rig.work(2)
        #expect(rig.host.probes == 2)
        rig.switchTo(Rig.word)
        rig.work(60)
        #expect(rig.host.probes == 2, "Nothing is read once it's out of front")
        #expect((rig.host.armed ?? 0) > 4)
    }

    @Test func onlyOneReadRunsAtATime() {
        let rig = Rig()
        rig.start(Rig.safari)
        rig.work(30)
        #expect(rig.host.probes == 1, "A hung browser is not asked again on top of itself")
        rig.host.answer(page("nature.com"))
        rig.work(4)
        #expect(rig.host.probes == 2)
    }





    @Test func aBrowserThatStopsAnsweringLosesItsSite() {
        let rig = Rig()
        rig.start(Rig.chrome)
        rig.host.answer(page("nature.com"))
        rig.work(4)
        rig.host.answer(nil)
        #expect(rig.stretches.count <= 1)
        rig.work(4)
        rig.host.answer(nil)
        rig.clock.advance(4)
        #expect(rig.stretches.map(\.site) == ["nature.com", nil])
    }

    @Test func serviceLabelsWinOverDomains() {
        let rig = Rig()
        rig.start(Rig.chrome)
        rig.host.answer(ActivityDetail(site: "Google Docs", title: nil, domain: "google.com"))
        rig.clock.advance(5)
        #expect(rig.stretches.map(\.site) == ["Google Docs"])
    }

    @Test func aReadFromBeforeAnAppSwitchIsThrownAway() {
        var settings = ActivityRecorderSettings(enabled: true)
        settings.titles = true
        let rig = Rig(settings: settings)
        rig.start(Rig.preview)
        rig.switchTo(Rig.word)
        rig.host.answer(ActivityDetail(site: nil, title: "Secret.pdf"))
        rig.clock.advance(10)
        #expect(rig.stretches.allSatisfy { $0.title != "Secret.pdf" })
    }

    @Test func documentTitlesFollowTheFocusedWindowWithNamesOn() {
        var settings = ActivityRecorderSettings(enabled: true)
        settings.titles = true
        let rig = Rig(settings: settings)
        rig.start(Rig.preview)
        rig.host.answer(ActivityDetail(site: nil, title: "Paper A.pdf"))
        rig.work(4)
        rig.host.answer(ActivityDetail(site: nil, title: "Paper B.pdf"))
        rig.clock.advance(4)
        #expect(rig.stretches.map(\.title) == ["Paper A.pdf", "Paper B.pdf"])
    }

    @Test func aRunningSessionSharesTheRecordersRead() {
        let rig = Rig()
        rig.start(Rig.chrome)
        rig.host.answer(page("nature.com"))
        #expect(rig.recorder.detail(forApp: Rig.chrome.id, pid: Rig.chrome.pid)?.domain == "nature.com")
        #expect(rig.recorder.detail(forApp: Rig.chrome.id, pid: 999) == nil)
        rig.clock.advance(6)
        #expect(rig.recorder.detail(forApp: Rig.chrome.id, pid: Rig.chrome.pid) == nil, "Too old to describe the window")
    }

    // MARK: Taking things back

    @Test func turningOffDropsTheStretchInProgressAndAnyLateRead() {
        var settings = ActivityRecorderSettings(enabled: true)
        settings.titles = true
        let rig = Rig(settings: settings)
        rig.start(Rig.preview)
        rig.host.answer(ActivityDetail(site: nil, title: "Kept.pdf"))
        rig.work(4)
        settings.enabled = false
        rig.clock.advance(4)
        rig.recorder.apply(settings)
        rig.host.answer(ActivityDetail(site: nil, title: "Late.pdf"))
        rig.clock.advance(60)
        rig.recorder.frontAppDidChange()
        rig.recorder.stop()
        #expect(rig.host.armed == nil)
        #expect(rig.day("2026-11-04") == nil, "Off discards what was never finished")
    }

    @Test func turningOffKeepsFinishedStretches() {
        let rig = Rig()
        rig.start(Rig.word)
        rig.clock.advance(30)
        rig.switchTo(Rig.mail)
        rig.clock.advance(30)
        var settings = rig.recorder.settings
        settings.enabled = false
        rig.recorder.apply(settings)
        #expect(rig.day("2026-11-04")?.stretches.map(\.appID) == [Rig.word.id])
    }

    @Test func clearRemovesEveryDayAndALateReadCannotRecreateIt() {
        var settings = ActivityRecorderSettings(enabled: true)
        settings.titles = true
        let rig = Rig(settings: settings)
        var old = ActivityDayLog(day: "2026-11-01")
        let then = rig.clock.now.addingTimeInterval(-86_400)
        old.add(FocusActivitySegment(start: then, end: then.addingTimeInterval(10), appID: "a", appName: "A"))
        rig.store.enqueue(.write(old))
        rig.start(Rig.preview)
        rig.host.answer(ActivityDetail(site: nil, title: "Paper.pdf"))
        rig.work(4)
        rig.recorder.clear()
        rig.host.answer(ActivityDetail(site: nil, title: "Paper.pdf"))
        #expect(rig.day("2026-11-01") == nil)
        #expect(rig.day("2026-11-04") == nil)
        #expect(rig.recorder.today().isEmpty)
    }

    @Test func removingNamesAppliesToTodayAndTheFiles() {
        var settings = ActivityRecorderSettings(enabled: true)
        settings.titles = true
        let rig = Rig(settings: settings)
        rig.start(Rig.preview)
        rig.host.answer(ActivityDetail(site: nil, title: "Paper.pdf"))
        rig.work(4)
        rig.host.answer(ActivityDetail(site: nil, title: "Other.pdf"))
        rig.work(4)
        rig.host.answer(ActivityDetail(site: nil, title: "Other.pdf"))
        rig.recorder.stop()
        #expect(rig.day("2026-11-04")?.hasTitles == true)

        let again = Rig(settings: settings)
        again.start(Rig.preview)
        again.host.answer(ActivityDetail(site: nil, title: "Paper.pdf"))
        again.work(4)
        again.host.answer(ActivityDetail(site: nil, title: "Other.pdf"))
        again.clock.advance(4)
        again.recorder.removeTitles()
        #expect(!again.recorder.today().hasTitles)
        again.recorder.stop()
        #expect(again.day("2026-11-04")?.hasTitles == false)
        #expect(again.day("2026-11-04")?.seconds == 8, "Times stay")
    }

    @Test func excludingAnAppLeavesTodayAndPastDaysOnDisk() {
        let rig = Rig()
        var old = ActivityDayLog(day: "2026-11-01")
        let then = rig.clock.now.addingTimeInterval(-86_400)
        old.add(FocusActivitySegment(start: then, end: then.addingTimeInterval(10), appID: Rig.mail.id, appName: "Mail"))
        old.add(FocusActivitySegment(start: then.addingTimeInterval(10), end: then.addingTimeInterval(20), appID: Rig.word.id, appName: "Word"))
        rig.store.enqueue(.write(old))
        rig.start(Rig.mail)
        rig.clock.advance(30)
        rig.switchTo(Rig.word)
        rig.clock.advance(30)
        var settings = rig.recorder.settings
        settings.excluded = [Rig.mail.id]
        rig.recorder.apply(settings)
        rig.recorder.stop()
        #expect(rig.day("2026-11-01")?.totals.map(\.appID) == [Rig.mail.id, Rig.word.id])
        #expect(rig.day("2026-11-04")?.stretches.map(\.appID) == [Rig.mail.id, Rig.word.id])
    }


    @Test func turningNamesOffStripsTheOpenStretch() {
        var settings = ActivityRecorderSettings(enabled: true)
        settings.titles = true
        let rig = Rig(settings: settings)
        rig.start(Rig.preview)
        rig.host.answer(ActivityDetail(site: nil, title: "Paper.pdf"))
        rig.clock.advance(5)
        settings.titles = false
        rig.recorder.apply(settings)
        #expect(!rig.recorder.today().hasTitles)
    }

    @Test func retentionPrunesOnStartAndAtTheDayChange() {
        var settings = ActivityRecorderSettings(enabled: true)
        settings.retentionDays = 30
        let rig = Rig(settings: settings)
        for key in ["2026-09-30", "2026-10-05", "2026-10-06", "2026-11-03"] {
            var log = ActivityDayLog(day: key)
            log.add(FocusActivitySegment(start: rig.clock.now, end: rig.clock.now.addingTimeInterval(10), appID: "a", appName: "A"))
            rig.store.enqueue(.write(log))
        }
        rig.start(Rig.word)
        #expect(rig.day("2026-10-05") == nil)
        #expect(rig.day("2026-10-06") != nil, "The thirtieth day back, counting today")
        rig.clock.advance(86_400)
        rig.host.wake()
        #expect(rig.day("2026-10-06") == nil)
        #expect(rig.day("2026-11-03") != nil)
    }

    @Test func foreverKeepsEveryDay() {
        var settings = ActivityRecorderSettings(enabled: true)
        settings.retentionDays = 0
        let rig = Rig(settings: settings)
        var log = ActivityDayLog(day: "2020-01-01")
        log.add(FocusActivitySegment(start: rig.clock.now, end: rig.clock.now.addingTimeInterval(10), appID: "a", appName: "A"))
        rig.store.enqueue(.write(log))
        rig.start(Rig.word)
        #expect(rig.day("2020-01-01") != nil)
    }
}

struct ActivitySystemIdleTests {
    /// The one call that could silently disable idle detection: the "any
    /// input" value has no named case, and a nil here would mean never idle.
    @Test func anyInputEventTypeExists() {
        #expect(CGEventType(rawValue: ~0) != nil)
    }
}

@MainActor
extension ActivityRecorderTests {
    @Test func resumingFocusAfterSleepNeverBackdatesAcrossSleep() {
        let rig = Rig()
        rig.recorder.setFocusRunning(true)
        rig.start()
        rig.leave(60)
        rig.recorder.systemWillSleep()
        rig.recorder.setFocusRunning(false)
        rig.clock.advance(3600)
        rig.host.idle += 3600
        rig.recorder.systemDidWake()
        rig.recorder.setFocusRunning(true)
        rig.leave(10)
        #expect(rig.total == 70)
    }

    @Test func startingFocusAfterIdleCountsOnlyTheNewSession() {
        let rig = Rig()
        rig.start()
        rig.leave(300)
        rig.recorder.setFocusRunning(true)
        rig.leave(10)
        #expect(rig.total == 10)
    }

    @Test func idleCorrectsPeriodicSnapshotsOnDiskImmediately() {
        let rig = Rig()
        rig.start()
        rig.leave(120)
        rig.leave(120)
        #expect(rig.day("2026-11-04")?.seconds == 240)
        rig.leave(60)
        #expect(rig.total == 0)
        #expect(rig.day("2026-11-04")?.seconds ?? 0 == 0)
        rig.recorder.stop()
        #expect(rig.day("2026-11-04")?.seconds ?? 0 == 0)
    }

    @Test func idleRetractsThePreviousDaysProvisionalTail() {
        let rig = Rig(at: "2026-11-04T23:57:00Z")
        rig.start()
        rig.work(60)
        rig.leave(120)
        rig.leave(120)
        rig.leave(60)
        rig.recorder.stop()
        #expect(rig.day("2026-11-04")?.seconds == 60)
        #expect(rig.total == 0)
    }

    @Test func idleRetractsAlreadyClosedContextChanges() {
        let rig = Rig()
        rig.start()
        rig.work(10)
        rig.leave(120)
        rig.switchTo(Rig.mail)
        rig.leave(180)
        #expect(rig.total == 10)
        #expect(rig.day("2026-11-04")?.seconds == 10)
    }

    @Test func aPendingProbeDoesNotScheduleOneSecondWakeups() {
        let rig = Rig()
        rig.start(Rig.safari)
        rig.work(4)
        #expect(rig.host.probes == 1)
        #expect(rig.host.armed == 116)
    }

    @Test func aReadHeldAcrossLockCannotNameTheReopenedWindow() {
        let rig = Rig()
        rig.start(Rig.safari)
        rig.clock.advance(1)
        rig.recorder.screenDidLock()
        rig.clock.advance(1)
        rig.recorder.screenDidUnlock()
        rig.host.answer(page("old.example"))
        rig.clock.advance(1)
        #expect(rig.stretches.allSatisfy { $0.site == nil })
        #expect(rig.recorder.detail(forApp: Rig.safari.id, pid: Rig.safari.pid) == nil)
    }

    @Test func aSlowReadCannotBecomeFreshWhenItFinallyAnswers() {
        let rig = Rig()
        rig.start(Rig.safari)
        rig.clock.advance(30)
        rig.host.answer(page("old.example"))
        #expect(rig.recorder.detail(forApp: Rig.safari.id, pid: Rig.safari.pid) == nil)
        #expect(rig.stretches.allSatisfy { $0.site == nil })
    }

    @Test func aProbeAtTheIdleBoundaryCannotFileIdleTime() {
        let rig = Rig()
        rig.start(Rig.safari)
        rig.host.answer(page("first.example"))
        rig.leave(299)
        rig.clock.advance(1)
        rig.host.idle += 1
        rig.host.answer(page("second.example"))
        #expect(rig.total == 0)
        #expect(rig.recorder.isIdle)
    }

    @Test func settingTheClockBackResetsProbeAndSaveDeadlines() {
        let rig = Rig()
        rig.start(Rig.safari)
        rig.host.answer(page("first.example"))
        rig.clock.advance(-3600)
        rig.recorder.clockDidChange()
        #expect(rig.recorder.detail(forApp: Rig.safari.id, pid: Rig.safari.pid) == nil)
        #expect(rig.host.probes == 2)
        if rig.host.probes == 2 { rig.host.answer(page("second.example")) }
        rig.work(120)
        #expect(rig.day("2026-11-04")?.seconds == 120)
    }

    @Test func differentPagePathsKeepTheirOwnRecordedTime() {
        let rig = Rig()
        rig.start(Rig.safari)
        rig.host.answer(ActivityDetail(site: nil, title: nil, domain: "example.com", url: "https://example.com/work"))
        rig.work(4)
        rig.host.answer(ActivityDetail(site: nil, title: nil, domain: "example.com", url: "https://example.com/play"))
        rig.clock.advance(4)
        #expect(rig.stretches.map(\.url) == ["https://example.com/work", "https://example.com/play"])
        #expect(rig.stretches.map(\.seconds) == [4, 4])
    }

    @Test func queryOnlyPageChangesStillCoalesce() {
        let rig = Rig()
        rig.start(Rig.safari)
        rig.host.answer(ActivityDetail(site: nil, title: nil, domain: "example.com", url: "https://example.com/work?q=1"))
        rig.work(4)
        rig.host.answer(ActivityDetail(site: nil, title: nil, domain: "example.com", url: "https://example.com/work?q=2"))
        rig.clock.advance(4)
        #expect(rig.stretches.count == 1)
        #expect(rig.total == 8)
    }

    @Test func turningOffRetractsTheSavedOpenStretch() {
        let rig = Rig()
        rig.start()
        rig.work(120)
        #expect(rig.day("2026-11-04")?.seconds == 120)
        var settings = rig.recorder.settings
        settings.enabled = false
        rig.recorder.apply(settings)
        #expect(rig.day("2026-11-04")?.seconds ?? 0 == 0)
    }

    @Test func sleepFlushesTheFinalSecondsWithoutWaitingForAnotherTimer() {
        let rig = Rig()
        rig.start()
        rig.work(120)
        rig.clock.advance(30)
        rig.recorder.systemWillSleep()
        #expect(rig.day("2026-11-04")?.seconds == 150)
        #expect(rig.host.armed == nil)
    }

    @Test func idleCorrectionPreservesLoadedHistoryAndSessionTime() {
        let rig = Rig()
        var old = ActivityDayLog(day: "2026-11-04")
        old.add(FocusActivitySegment(start: rig.clock.now, end: rig.clock.now.addingTimeInterval(40), appID: Rig.mail.id, appName: "Mail"))
        rig.store.enqueue(.write(old))
        rig.recorder.setFocusRunning(true)
        rig.start()
        rig.leave(120)
        rig.recorder.setFocusRunning(false)
        rig.switchTo(Rig.mail)
        rig.leave(180)
        #expect(rig.total == 160)
        #expect(rig.day("2026-11-04")?.seconds == 160)
    }

    @Test func idleCorrectionPreservesTotalsBeyondTheTimelineCap() {
        let rig = Rig()
        rig.start()
        let worked = ActivityDayLog.stretchLimit + 5
        for index in 0..<worked {
            rig.clock.advance(1)
            rig.switchTo(index.isMultiple(of: 2) ? Rig.mail : Rig.word)
        }
        #expect(rig.recorder.today().truncated)
        rig.leave(120)
        rig.switchTo(Rig.mail)
        rig.leave(180)
        #expect(rig.total == TimeInterval(worked))
        #expect(rig.day("2026-11-04")?.seconds == TimeInterval(worked))
        #expect(rig.stretches.count <= ActivityDayLog.stretchLimit)
    }

    @Test func idleCorrectionNeverRecreatesARetentionPrunedDay() {
        let rig = Rig(settings: ActivityRecorderSettings(enabled: true, retentionDays: 1), at: "2026-11-04T23:57:00Z")
        rig.start()
        rig.work(60)
        rig.leave(120)
        #expect(rig.day("2026-11-04") == nil)
        rig.leave(180)
        rig.recorder.stop()
        #expect(rig.day("2026-11-04") == nil)
        #expect(rig.total == 0)
    }

    @Test func elapsedPauseDoesNotRetractTimeBeforeThePause() {
        let rig = Rig()
        rig.start()
        rig.leave(30)
        var settings = rig.recorder.settings
        settings.pausedUntil = rig.clock.now.addingTimeInterval(3600)
        rig.recorder.apply(settings)
        rig.leave(3600)
        #expect(rig.total == 30)
        #expect(rig.day("2026-11-04")?.seconds == 30)
    }

    @Test func idlePollingDoesNotKeepRewritingTheCorrectedDay() {
        let rig = Rig()
        var saves = 0
        rig.recorder.onSave = { saves += 1 }
        rig.start()
        rig.leave(120)
        rig.leave(180)
        let settled = saves
        for _ in 0..<10 { rig.leave(10) }
        #expect(saves == settled)
        #expect(rig.host.armed == ActivityRecorder.idlePollInterval)
    }

    @Test func repeatedStartStopKeepsSeparateStretchesAndFreshProbes() {
        let rig = Rig()
        rig.start(Rig.safari)
        rig.host.answer(page("first.example"))
        rig.clock.advance(10)
        rig.recorder.stop()
        rig.clock.advance(100)
        rig.recorder.start()
        #expect(rig.host.probes == 2)
        if rig.host.probes == 2 { rig.host.answer(page("second.example")) }
        rig.clock.advance(10)
        #expect(rig.total == 20)
        #expect(rig.stretches.map(\.site) == ["first.example", "second.example"])
        #expect(!ActivityTimeline.touches(rig.stretches[0], rig.stretches[1]))
    }

    @Test func repeatedSlowReadFailuresStillClearTheRecordedSite() {
        let rig = Rig()
        rig.start(Rig.safari)
        rig.host.answer(page("old.example"))
        for _ in 0..<2 {
            rig.work(4)
            rig.clock.advance(6)
            rig.host.answer(nil)
        }
        rig.clock.advance(4)
        #expect(rig.stretches.map(\.site) == ["old.example", nil])
    }

    @Test func removingTitlesKeepsLoadedHistoryOutsideIdleCorrection() {
        let rig = Rig()
        var old = ActivityDayLog(day: "2026-11-04")
        for index in 0..<2 {
            let start = rig.clock.now.addingTimeInterval(Double(index * 20))
            old.add(FocusActivitySegment(start: start, end: start.addingTimeInterval(20), appID: Rig.mail.id,
                                         appName: "Mail", title: "Old \(index)"))
        }
        rig.store.enqueue(.write(old))
        rig.start()
        rig.leave(120)
        rig.recorder.removeTitles()
        rig.leave(180)
        #expect(rig.total == 40)
        #expect(rig.day("2026-11-04")?.seconds == 40)
        #expect(!rig.recorder.today().hasTitles)
    }

    @Test func idleWhileDisabledDoesNotRetractFinishedHistory() {
        let rig = Rig()
        rig.start()
        rig.leave(30)
        rig.switchTo(Rig.mail)
        var settings = rig.recorder.settings
        settings.enabled = false
        rig.recorder.apply(settings)
        rig.clock.advance(600)
        rig.host.idle += 600
        #expect(rig.total == 30)
        rig.recorder.stop()
        #expect(rig.day("2026-11-04")?.seconds == 30)
    }
}
