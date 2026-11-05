import Foundation
import Testing
@testable import Nidus

// MARK: Helpers

private func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

private func moment(_ cal: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func seg(_ start: Double, _ end: Double, app: String = "com.a", name: String = "A",
                 site: String? = nil, title: String? = nil, continuity: Int = 0) -> FocusActivitySegment {
    FocusActivitySegment(start: base.addingTimeInterval(start), end: base.addingTimeInterval(end),
                         appID: app, appName: name, site: site, title: title, continuity: continuity)
}

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("nidus-day-tests-" + UUID().uuidString, isDirectory: true)
}

private func dayLog(_ day: String, _ stretches: [FocusActivitySegment]) -> ActivityDayLog {
    var log = ActivityDayLog(day: day)
    for stretch in stretches { log.add(stretch) }
    return log
}

/// Stands in for the file work and notes what was asked, optionally holding
/// the first change until released.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    private var first = true
    private let hold: Bool
    let started = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0)

    init(hold: Bool) { self.hold = hold }

    var changes: [String] { lock.withLock { seen } }

    func perform(_ change: ActivityDayStore.Change) {
        let isFirst: Bool = lock.withLock {
            seen.append(Recorder.tag(change))
            defer { first = false }
            return first
        }
        if hold && isFirst {
            started.signal()
            gate.wait()
        }
    }

    static func tag(_ change: ActivityDayStore.Change) -> String {
        switch change {
        case .write(let log): return "write \(log.day) \(Int(log.seconds))"
        case .clear: return "clear"
        case .removeTitles: return "removeTitles"
        case .remove(let apps): return "remove \(apps.sorted().joined(separator: ","))"
        case .prune(let before): return "prune \(before)"
        }
    }
}

private func writeLog(_ day: String, seconds: Double) -> ActivityDayStore.Change {
    .write(dayLog(day, [seg(0, seconds)]))
}

// MARK: Domain

struct ActivityDomainTests {
    @Test func stripsEverythingButTheSite() {
        #expect(ActivityDomain.site(from: "https://User:pw@WWW.Nature.com:8443/articles/x?y=1#z") == "nature.com")
        #expect(ActivityDomain.site(from: "HTTP://Example.COM./a/b") == "example.com")
        #expect(ActivityDomain.site(from: "https://example.com") == "example.com")
    }

    @Test func reducesToTheRegistrableDomain() {
        let table: [(String, String)] = [
            ("https://lab.slack.com/x", "slack.com"),
            ("https://a.b.example.co.uk/", "example.co.uk"),
            ("https://www.bbc.co.uk/news", "bbc.co.uk"),
            ("https://lab.ox.ac.uk/", "ox.ac.uk"),
            ("https://foo.ac.jp/", "foo.ac.jp"),
            ("https://x.foo.ac.jp/", "foo.ac.jp"),
            ("https://sub.example.com.au/", "example.com.au"),
            ("https://someone.github.io/", "someone.github.io"),
            ("https://repo.someone.github.io/", "someone.github.io"),
            ("https://pubmed.ncbi.nlm.nih.gov/123/", "pubmed.ncbi.nlm.nih.gov"),
            ("https://www.ncbi.nlm.nih.gov/gene", "ncbi.nlm.nih.gov"),
            ("https://ncbi.nlm.nih.gov/", "ncbi.nlm.nih.gov"),
            ("https://www.nih.gov/", "nih.gov"),
            ("https://docs.google.com/document/d/1", "google.com"),
            ("https://a.b.example.org/", "example.org"),
        ]
        for (input, expected) in table {
            #expect(ActivityDomain.site(from: input) == expected, "\(input)")
        }
    }

    @Test func rejectsWhatIsNotAPublicSite() {
        let rejected = [
            "file:///Users/me/a.pdf", "about:blank", "chrome://settings", "data:text/html,hi",
            "mailto:a@b.com", "ftp://example.com/f", "javascript:alert(1)",
            "http://localhost:3000/x", "http://printer.local/", "http://nas.home/", "http://intranet/wiki",
            "http://192.168.1.4/", "http://192.168.1.4:8080/a", "http://10.0.0.1", "http://[::1]/", "http://[::1]:8080/x",
            "http://singlelabel/", "", "not a url", "https://", "https://-bad-.com/",
        ]
        for input in rejected {
            #expect(ActivityDomain.site(from: input) == nil, "\(input)")
        }
    }

    @Test func aSiteNeverCarriesURLPunctuation() {
        let inputs = [
            "https://User:pw@WWW.Nature.com:8443/articles/x?y=1#z", "http://a.b.example.co.uk:80/p?q=@x:y",
            "https://user@lab.slack.com/", "https://x.github.io/a/b", "https://pubmed.ncbi.nlm.nih.gov:443/?term=a/b",
        ]
        for input in inputs {
            let site = ActivityDomain.site(from: input)
            #expect(site != nil, "\(input)")
            for character in ["/", "?", "@", ":", "#"] {
                #expect(site?.contains(character) == false, "\(input) -> \(site ?? "nil")")
            }
        }
    }

    @Test func isDomainRecognizesOnlyBareDomains() {
        #expect(ActivityDomain.isDomain("nature.com"))
        #expect(ActivityDomain.isDomain("xn--mnchen-3ya.de"))
        for text in ["Google Docs", "nature.com/x", "https://nature.com", "nature.com:80", "1.2.3.4", "localhost", "a.local", "Nature.com", "a..com"] {
            #expect(!ActivityDomain.isDomain(text), "\(text)")
        }
    }

    @Test func safeDaySiteKeepsLabelsAndDomainsOnly() {
        #expect(ActivityTimeline.safeDaySite("Google Docs") == "Google Docs")
        #expect(ActivityTimeline.safeDaySite("Claude Science") == "Claude Science")
        #expect(ActivityTimeline.safeDaySite("nature.com") == "nature.com")
        #expect(ActivityTimeline.safeDaySite("ox.ac.uk") == "ox.ac.uk")
        #expect(ActivityTimeline.safeDaySite(nil) == nil)
        for text in ["https://x.y/z", "nature.com/articles", "nature.com?x=1", "user@nature.com", "Some Other Label", "", "localhost"] {
            #expect(ActivityTimeline.safeDaySite(text) == nil, "\(text)")
        }
    }
}

// MARK: Probe

struct ActivityProbePureTests {


    @Test func documentTitlesLoseWhatChangesWithinADocument() {
        let preview = ActivityProbe.previewID
        #expect(ActivityProbe.documentTitle("Paper.pdf (page 3 of 12)", bundleID: preview) == "Paper.pdf")
        #expect(ActivityProbe.documentTitle("Paper.pdf – Page 3 of 12", bundleID: preview) == "Paper.pdf")
        #expect(ActivityProbe.documentTitle("Paper.pdf - Page 3 of 12", bundleID: preview) == "Paper.pdf")
        #expect(ActivityProbe.documentTitle("Paper.pdf", bundleID: preview) == "Paper.pdf")
        for acrobat in ActivityProbe.acrobatIDs {
            #expect(ActivityProbe.documentTitle("Paper.pdf - Adobe Acrobat Reader", bundleID: acrobat) == "Paper.pdf")
            #expect(ActivityProbe.documentTitle("Paper.pdf (page 3 of 12)", bundleID: acrobat) == "Paper.pdf (page 3 of 12)")
        }
        // Other apps, and the other app's suffix, are left as written.
        #expect(ActivityProbe.documentTitle("Draft (page 3 of 12)", bundleID: ActivityProbe.wordID) == "Draft (page 3 of 12)")
        #expect(ActivityProbe.documentTitle("Paper.pdf - Adobe Acrobat Reader", bundleID: preview) == "Paper.pdf - Adobe Acrobat Reader")
        #expect(ActivityProbe.documentTitle("Paper.pdf - Adobe Acrobat Reader", bundleID: "com.example.other") == "Paper.pdf - Adobe Acrobat Reader")
        #expect(ActivityProbe.documentTitle(nil, bundleID: preview) == nil)
    }

    @Test func needsProbeFollowsTitlesExceptForBrowsers() {
        for browser in BrowserProfile.known {
            #expect(ActivityProbe.needsProbe(browser.bundleID, titles: true))
            #expect(ActivityProbe.needsProbe(browser.bundleID, titles: false))
        }
        #expect(ActivityProbe.needsProbe(ActivityProbe.previewID, titles: true))
        #expect(!ActivityProbe.needsProbe(ActivityProbe.previewID, titles: false))
        for acrobat in ActivityProbe.acrobatIDs {
            #expect(ActivityProbe.needsProbe(acrobat, titles: true))
            #expect(!ActivityProbe.needsProbe(acrobat, titles: false))
        }
        #expect(!ActivityProbe.needsProbe("com.example.other", titles: false))
    }

    @Test func aSessionKeepsTheDomainAndTitleButNoAddress() {
        let page = ActivityDetail(site: nil, title: "A page", domain: "example.com", url: "https://example.com/a")
        #expect(page.forSession == ActivityDetail(site: "example.com", title: "A page"))
        let service = ActivityDetail(site: "Google Docs", title: "Thesis", domain: "google.com")
        #expect(service.forSession == ActivityDetail(site: "Google Docs", title: "Thesis"))
        #expect(ActivityDetail(site: nil, title: "Draft").forSession == ActivityDetail(site: nil, title: "Draft"))
    }

    @Test func onlyAWebPagesAddressIsKept() {
        #expect(ActivityProbe.keptURL("https://nature.com/a?b=1#c") == "https://nature.com/a?b=1#c")
        #expect(ActivityProbe.keptURL("file:///Users/me/a.pdf") == nil)
        #expect(ActivityProbe.keptURL("about:blank") == nil)
        #expect(ActivityProbe.keptURL("https://a.com/" + String(repeating: "x", count: ActivityProbe.urlLimit)) == nil)
        #expect(ActivityProbe.keptURL(nil) == nil)
    }

    @Test func withNamesOnEveryAppIsRead() {
        #expect(ActivityProbe.needsProbe("com.example.anything", titles: true))
        #expect(!ActivityProbe.needsProbe("com.example.anything", titles: false))
        #expect(ActivityProbe.needsProbe(BrowserProfile.safari.bundleID, titles: false))
    }
}

// MARK: Day log

struct ActivityDayLogTests {
    @Test func touchingStretchesOfOneContextMerge() {
        var log = ActivityDayLog(day: "2026-01-05")
        log.add(seg(0, 10))
        log.add(seg(10, 25))
        #expect(log.stretches.count == 1)
        #expect(log.stretches[0].start == base)
        #expect(log.stretches[0].end == base.addingTimeInterval(25))
        #expect(log.totals.count == 1)
        #expect(log.totals[0].seconds == 25)
        #expect(log.seconds == 25)
    }

    @Test func aGapKeepsStretchesApartButTotalsAdd() {
        var log = ActivityDayLog(day: "2026-01-05")
        log.add(seg(0, 10))
        log.add(seg(15, 25))
        #expect(log.stretches.count == 2)
        #expect(log.totals.count == 1)
        #expect(log.totals[0].seconds == 20)
    }

    @Test func aChangeOfContextOrContinuityKeepsStretchesApart() {
        var byTitle = ActivityDayLog(day: "2026-01-05")
        byTitle.add(seg(0, 10, title: "One"))
        byTitle.add(seg(10, 20, title: "Two"))
        #expect(byTitle.stretches.count == 2)
        #expect(byTitle.totals.count == 2)

        var byApp = ActivityDayLog(day: "2026-01-05")
        byApp.add(seg(0, 10))
        byApp.add(seg(10, 20, app: "com.b", name: "B"))
        #expect(byApp.stretches.count == 2)
        #expect(byApp.totals.count == 2)

        var bySite = ActivityDayLog(day: "2026-01-05")
        bySite.add(seg(0, 10, site: "nature.com"))
        bySite.add(seg(10, 20, site: "slack.com"))
        #expect(bySite.stretches.count == 2)

        var byContinuity = ActivityDayLog(day: "2026-01-05")
        byContinuity.add(seg(0, 10, continuity: 0))
        byContinuity.add(seg(10, 20, continuity: 1))
        #expect(byContinuity.stretches.count == 2)
        #expect(byContinuity.totals.count == 1)
        #expect(byContinuity.totals[0].seconds == 20)
    }

    @Test func emptyOrBackwardsStretchesAreIgnored() {
        var log = ActivityDayLog(day: "2026-01-05")
        log.add(seg(10, 10))
        log.add(seg(20, 10))
        #expect(log.isEmpty)
    }

    @Test func theStretchLimitDropsTheOldestAndKeepsTotalsComplete() {
        var log = ActivityDayLog(day: "2026-01-05")
        let count = ActivityDayLog.stretchLimit + 5
        for index in 0..<count { log.add(seg(Double(index * 10), Double(index * 10 + 1))) }
        #expect(log.stretches.count == ActivityDayLog.stretchLimit)
        #expect(log.truncated)
        #expect(log.stretches.first?.start == base.addingTimeInterval(Double(5 * 10)))
        #expect(log.stretches.last?.start == base.addingTimeInterval(Double((count - 1) * 10)))
        #expect(log.totals.count == 1)
        #expect(log.totals[0].seconds == Double(count))
        #expect(log.seconds == Double(count))
    }

    @Test func stayingUnderTheStretchLimitDoesNotTruncate() {
        var log = ActivityDayLog(day: "2026-01-05")
        for index in 0..<10 { log.add(seg(Double(index * 10), Double(index * 10 + 1))) }
        #expect(!log.truncated)
    }

    @Test func theTotalsLimitFoldsNamesIntoOneRowAndKeepsTheTime() {
        var log = ActivityDayLog(day: "2026-01-05")
        for index in 0..<ActivityDayLog.totalsLimit {
            log.add(seg(Double(index * 10), Double(index * 10 + 1), title: "t\(index)"))
        }
        #expect(log.totals.count == ActivityDayLog.totalsLimit)
        let before = log.seconds

        let at = Double(ActivityDayLog.totalsLimit * 10)
        log.add(seg(at, at + 7, title: "extra"))
        #expect(log.totals.count == ActivityDayLog.totalsLimit + 1)
        let folded = log.totals.filter { $0.title == nil }
        #expect(folded.count == 1)
        #expect(folded[0].appID == "com.a")
        #expect(folded[0].seconds == 7)

        log.add(seg(at + 20, at + 25, title: "extra again"))
        #expect(log.totals.count == ActivityDayLog.totalsLimit + 1)
        #expect(log.totals.filter { $0.title == nil }[0].seconds == 12)
        #expect(log.seconds == before + 12)

        // A name that already has a row still adds to it.
        log.add(seg(at + 40, at + 44, title: "t0"))
        #expect(log.totals.first { $0.title == "t0" }?.seconds == 5)
        #expect(log.totals.count == ActivityDayLog.totalsLimit + 1)
        // The stretches still carry the names.
        #expect(log.stretches.contains { $0.title == "extra" })
    }

    @Test func keyIsZeroPaddedInTheGivenCalendar() {
        let ny = calendar("America/New_York")
        let utc = calendar("UTC")
        #expect(ActivityDayLog.key(for: moment(ny, 2026, 1, 5, 9), calendar: ny) == "2026-01-05")
        #expect(ActivityDayLog.key(for: moment(ny, 2026, 12, 31, 23, 30), calendar: ny) == "2026-12-31")
        // 23:30 in New York is already the next day in UTC.
        let late = moment(ny, 2026, 1, 5, 23, 30)
        #expect(ActivityDayLog.key(for: late, calendar: ny) == "2026-01-05")
        #expect(ActivityDayLog.key(for: late, calendar: utc) == "2026-01-06")
        #expect(ActivityDayStore.isDayKey(ActivityDayLog.key(for: late, calendar: ny)))
    }

    @Test func retentionStartCountsTodayAsDayOne() {
        let ny = calendar("America/New_York")
        let today = moment(ny, 2026, 4, 10, 15)
        #expect(ActivityDayLog.retentionStart(days: 0, today: today, calendar: ny) == nil)
        #expect(ActivityDayLog.retentionStart(days: -3, today: today, calendar: ny) == nil)
        #expect(ActivityDayLog.retentionStart(days: 1, today: today, calendar: ny) == "2026-04-10")
        #expect(ActivityDayLog.retentionStart(days: 2, today: today, calendar: ny) == "2026-04-09")
        // 90 days is 2026-01-11 through 2026-04-10 inclusive.
        #expect(ActivityDayLog.retentionStart(days: 90, today: today, calendar: ny) == "2026-01-11")
    }

    @Test func removeTitlesMergesRowsAndKeepsBoundaries() {
        var log = ActivityDayLog(day: "2026-01-05")
        log.add(seg(0, 10, title: "One"))
        log.add(seg(10, 20, title: "Two"))
        #expect(log.hasTitles)
        log.removeTitles()
        #expect(!log.hasTitles)
        #expect(log.totals.count == 1)
        #expect(log.totals[0].seconds == 20)
        #expect(log.stretches.count == 2)
        #expect(log.stretches.allSatisfy { $0.title == nil })
        // The switch between documents is still a switch.
        #expect(!ActivityTimeline.touches(log.stretches[0], log.stretches[1]))
        #expect(log.seconds == 20)
    }

    @Test func removingAppsLeavesAGapSoNeighborsDoNotMerge() {
        var log = ActivityDayLog(day: "2026-01-05")
        log.add(seg(0, 10))
        log.add(seg(10, 20, app: "com.b", name: "B"))
        log.add(seg(20, 30))
        #expect(log.stretches.count == 3)
        log.remove(apps: ["com.b"])
        #expect(log.totals.map(\.appID) == ["com.a"])
        #expect(log.totals[0].seconds == 20)
        #expect(log.stretches.count == 2)
        #expect(!ActivityTimeline.touches(log.stretches[0], log.stretches[1]))
        #expect(log.stretches[1].continuity > log.stretches[0].continuity)

        log.remove(apps: ["com.a"])
        #expect(log.isEmpty)
    }

    @Test func sanitizingDropsUnsafeSitesAndNonPositiveRows() {
        var log = ActivityDayLog(day: "2026-01-05")
        log.totals = [
            FocusActivity(appID: "a", appName: "A", site: "https://x.y/z", seconds: 5),
            FocusActivity(appID: "a", appName: "A", site: "Google Docs", seconds: 5),
            FocusActivity(appID: "a", appName: "A", site: "nature.com", seconds: 5),
            FocusActivity(appID: "a", appName: "A", site: "nature.com/x", seconds: 5),
            FocusActivity(appID: "a", appName: "A", seconds: 0),
            FocusActivity(appID: "a", appName: "A", seconds: -3),
            FocusActivity(appID: "a", appName: "A", seconds: .nan),
            FocusActivity(appID: "a", appName: "A", seconds: .infinity),
        ]
        log.stretches = [
            seg(0, 10, site: "https://x.y/z"),
            seg(10, 20, site: "nature.com"),
            seg(30, 30),
            seg(50, 40),
        ]
        let clean = log.sanitized
        #expect(clean.totals.count == 4)
        #expect(clean.totals.map(\.site) == [nil, "Google Docs", "nature.com", nil])
        #expect(clean.stretches.count == 2)
        #expect(clean.stretches.map(\.site) == [nil, "nature.com"])
        #expect(clean.day == log.day)
    }

    @Test func splitAtMidnight() {
        let ny = calendar("America/New_York")
        let original = FocusActivitySegment(start: moment(ny, 2026, 1, 10, 23, 50), end: moment(ny, 2026, 1, 11, 0, 10),
                                            appID: "com.a", appName: "A", site: "nature.com", title: "T", continuity: 4)
        let pieces = ActivityDayLog.split(original, calendar: ny)
        #expect(pieces.map(\.day) == ["2026-01-10", "2026-01-11"])
        #expect(pieces[0].stretch.start == original.start)
        #expect(pieces[0].stretch.end == moment(ny, 2026, 1, 11))
        #expect(pieces[1].stretch.start == moment(ny, 2026, 1, 11))
        #expect(pieces[1].stretch.end == original.end)
        #expect(pieces[0].stretch.seconds == 600)
        #expect(pieces[1].stretch.seconds == 600)
        #expect(pieces[0].stretch.id == original.id)
        #expect(pieces[1].stretch.id != original.id)
        for piece in pieces.map(\.stretch) {
            #expect(piece.appID == "com.a" && piece.site == "nature.com" && piece.title == "T" && piece.continuity == 4)
        }
    }

    @Test func aStretchInsideOneDayOrEndingAtMidnightIsNotSplit() {
        let ny = calendar("America/New_York")
        let inside = FocusActivitySegment(start: moment(ny, 2026, 1, 10, 9), end: moment(ny, 2026, 1, 10, 10), appID: "a", appName: "A")
        let single = ActivityDayLog.split(inside, calendar: ny)
        #expect(single.count == 1 && single[0].day == "2026-01-10" && single[0].stretch == inside)

        let endsAtMidnight = FocusActivitySegment(start: moment(ny, 2026, 1, 10, 23), end: moment(ny, 2026, 1, 11), appID: "a", appName: "A")
        let pieces = ActivityDayLog.split(endsAtMidnight, calendar: ny)
        #expect(pieces.count == 1 && pieces[0].day == "2026-01-10" && pieces[0].stretch == endsAtMidnight)
    }

    @Test func splitAcrossTwoMidnights() {
        let ny = calendar("America/New_York")
        let original = FocusActivitySegment(start: moment(ny, 2026, 1, 10, 23), end: moment(ny, 2026, 1, 12, 1), appID: "a", appName: "A")
        let pieces = ActivityDayLog.split(original, calendar: ny)
        #expect(pieces.map(\.day) == ["2026-01-10", "2026-01-11", "2026-01-12"])
        let lengths: [Double] = pieces.map { $0.stretch.seconds }
        #expect(lengths == [3600, 86_400, 3600])
        let summed: Double = pieces.reduce(0) { $0 + $1.stretch.seconds }
        #expect(summed == original.seconds)
        #expect(pieces[0].stretch.start == original.start && pieces[2].stretch.end == original.end)
        #expect(pieces[0].stretch.end == pieces[1].stretch.start && pieces[1].stretch.end == pieces[2].stretch.start)
        #expect(Set(pieces.map(\.stretch.id)).count == 3)
    }

    @Test func splitOverASpringForwardDay() {
        let ny = calendar("America/New_York")
        // 2026-03-08 is 23 hours long in New York.
        let original = FocusActivitySegment(start: moment(ny, 2026, 3, 7, 22), end: moment(ny, 2026, 3, 9, 2), appID: "a", appName: "A")
        let pieces = ActivityDayLog.split(original, calendar: ny)
        #expect(pieces.map(\.day) == ["2026-03-07", "2026-03-08", "2026-03-09"])
        let lengths: [Double] = pieces.map { $0.stretch.seconds }
        #expect(lengths == [7200, 82_800, 7200])
        let summed: Double = pieces.reduce(0) { $0 + $1.stretch.seconds }
        #expect(summed == original.seconds)
        #expect(pieces[1].stretch.start == moment(ny, 2026, 3, 8))
        #expect(pieces[1].stretch.end == moment(ny, 2026, 3, 9))
    }

    @Test func splitOverAFallBackDay() {
        let ny = calendar("America/New_York")
        // 2026-11-01 is 25 hours long in New York.
        let original = FocusActivitySegment(start: moment(ny, 2026, 10, 31, 23), end: moment(ny, 2026, 11, 2, 1), appID: "a", appName: "A")
        let pieces = ActivityDayLog.split(original, calendar: ny)
        #expect(pieces.map(\.day) == ["2026-10-31", "2026-11-01", "2026-11-02"])
        let lengths: [Double] = pieces.map { $0.stretch.seconds }
        #expect(lengths == [3600, 90_000, 3600])
        let summed: Double = pieces.reduce(0) { $0 + $1.stretch.seconds }
        #expect(summed == original.seconds)
    }

    @Test func sliceCutsToRangesAndCreditsNothingOutside() {
        let ranges = [DateInterval(start: base.addingTimeInterval(10), end: base.addingTimeInterval(20)),
                      DateInterval(start: base.addingTimeInterval(50), end: base.addingTimeInterval(60))]
        let spanning = seg(0, 100)
        let inside = seg(12, 18, app: "com.b", name: "B")
        let outside = seg(25, 45, app: "com.c", name: "C")
        let touching = seg(20, 30, app: "com.d", name: "D")

        let sliced = ActivityDayLog.slice([spanning, inside, outside, touching], to: ranges)
        #expect(sliced.map(\.appID) == ["com.a", "com.b", "com.a"])
        #expect(sliced[0].start == base.addingTimeInterval(10) && sliced[0].end == base.addingTimeInterval(20))
        #expect(sliced[1].start == inside.start && sliced[1].end == inside.end && sliced[1].id == inside.id)
        #expect(sliced[2].start == base.addingTimeInterval(50) && sliced[2].end == base.addingTimeInterval(60))
        #expect(sliced[0].id != sliced[2].id)
        let credited: Double = sliced.reduce(0) { $0 + $1.seconds }
        #expect(credited == 26)
        for piece in sliced {
            #expect(ranges.contains { piece.start >= $0.start && piece.end <= $0.end })
        }
    }

    @Test func sliceKeepsAWhollyContainedStretchAsItWasAndSortsByStart() {
        let range = DateInterval(start: base, end: base.addingTimeInterval(100))
        let late = seg(40, 50)
        let early = seg(5, 10, app: "com.b", name: "B")
        let sliced = ActivityDayLog.slice([late, early], to: [range])
        #expect(sliced == [early, late])
        #expect(ActivityDayLog.slice([late], to: []).isEmpty)
    }
}

// MARK: Day store

struct ActivityDayStoreTests {
    private func rendered(_ store: ActivityDayStore, _ day: String) -> ActivityDayLog? { store.load(day: day) }

    @Test func writeThenLoadRoundTrips() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ActivityDayStore(directory: dir)
        let log = dayLog("2026-01-05", [seg(0, 10, site: "nature.com", title: "A paper"), seg(20, 30, app: "com.b", name: "B")])
        store.enqueue(.write(log))
        store.flush()
        #expect(store.load(day: "2026-01-05") == log)
        #expect(store.load(day: "2026-01-06") == nil)
    }

    @Test func dayFilesAreReadableOnlyByTheOwner() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ActivityDayStore(directory: dir)
        store.enqueue(writeLog("2026-01-05", seconds: 10))
        store.flush()
        let file = try FileManager.default.attributesOfItem(atPath: store.url(for: "2026-01-05").path)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func aWriteQueuedBeforeClearCannotSurviveIt() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ActivityDayStore(directory: dir)
        store.enqueue(writeLog("2026-01-05", seconds: 10))
        store.enqueue(writeLog("2026-01-06", seconds: 10))
        store.enqueue(.clear)
        store.flush()
        #expect(store.load(day: "2026-01-05") == nil)
        #expect(store.load(day: "2026-01-06") == nil)

        store.enqueue(writeLog("2026-01-07", seconds: 10))
        store.flush()
        #expect(store.load(day: "2026-01-07") != nil)
    }

    @Test func clearDropsPendingChangesButNotAnInProgressOne() {
        let recorder = Recorder(hold: true)
        let store = ActivityDayStore(directory: tempDirectory(), perform: { recorder.perform($0) })
        store.enqueue(writeLog("2026-01-05", seconds: 1))
        #expect(recorder.started.wait(timeout: .now() + 10) == .success)
        store.enqueue(writeLog("2026-01-06", seconds: 2))
        store.enqueue(.removeTitles)
        store.enqueue(.clear)
        recorder.gate.signal()
        store.flush()
        #expect(recorder.changes == ["write 2026-01-05 1", "clear"])
    }

    @Test func pruneDeletesOnlyOlderDayFilesAndLeavesOtherFilesAlone() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ActivityDayStore(directory: dir)
        for day in ["2026-01-01", "2026-01-04", "2026-01-05", "2026-01-10"] { store.enqueue(writeLog(day, seconds: 10)) }
        store.flush()
        let strangers = ["notes.json", "2026-01-01.txt", "2026-1-1.json", "backup-2026-01-01.json", "README"]
        for name in strangers { try Data("keep".utf8).write(to: dir.appendingPathComponent(name)) }

        store.enqueue(.prune(before: "2026-01-05"))
        store.flush()
        #expect(store.load(day: "2026-01-01") == nil)
        #expect(store.load(day: "2026-01-04") == nil)
        #expect(store.load(day: "2026-01-05") != nil)
        #expect(store.load(day: "2026-01-10") != nil)
        for name in strangers {
            #expect(try Data(contentsOf: dir.appendingPathComponent(name)) == Data("keep".utf8), "\(name)")
        }

        // Clearing is as careful.
        store.enqueue(.clear)
        store.flush()
        #expect(store.load(day: "2026-01-10") == nil)
        for name in strangers {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), "\(name)")
        }
    }

    @Test func removeTitlesRewritesEveryDayFile() async {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ActivityDayStore(directory: dir)
        store.enqueue(.write(dayLog("2026-01-05", [seg(0, 10, title: "One"), seg(10, 20, title: "Two")])))
        store.enqueue(.write(dayLog("2026-01-06", [seg(0, 10, site: "nature.com", title: "Paper")])))
        store.enqueue(.write(dayLog("2026-01-07", [seg(0, 10)])))
        store.flush()
        #expect(await store.hasTitles())

        store.enqueue(.removeTitles)
        store.flush()
        #expect(!(await store.hasTitles()))
        let days = await store.load(days: ["2026-01-05", "2026-01-06", "2026-01-07"])
        #expect(days.count == 3)
        #expect(days.allSatisfy { !$0.hasTitles })
        #expect(days[0].totals.count == 1)
        #expect(days[0].seconds == 20)
        #expect(days[1].totals.first?.site == "nature.com")
    }

    @Test func removingAppsRewritesEveryDayAndDeletesADayLeftEmpty() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ActivityDayStore(directory: dir)
        store.enqueue(.write(dayLog("2026-01-05", [seg(0, 10), seg(10, 20, app: "com.b", name: "B"), seg(20, 30)])))
        store.enqueue(.write(dayLog("2026-01-06", [seg(0, 10, app: "com.b", name: "B")])))
        store.enqueue(.write(dayLog("2026-01-07", [seg(0, 10)])))
        store.flush()

        store.enqueue(.remove(apps: ["com.b"]))
        store.flush()
        let first = try #require(store.load(day: "2026-01-05"))
        #expect(first.totals.map(\.appID) == ["com.a"])
        #expect(first.stretches.count == 2)
        #expect(!ActivityTimeline.touches(first.stretches[0], first.stretches[1]))
        #expect(store.load(day: "2026-01-06") == nil)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: "2026-01-06").path))
        #expect(store.load(day: "2026-01-07") != nil)
    }

    @Test func aBurstKeepsTheInProgressWriteAndTheNewestPerDay() {
        let recorder = Recorder(hold: true)
        let store = ActivityDayStore(directory: tempDirectory(), perform: { recorder.perform($0) })
        store.enqueue(writeLog("2026-01-05", seconds: 1))
        #expect(recorder.started.wait(timeout: .now() + 10) == .success)
        for seconds in [2.0, 3.0, 4.0, 5.0] { store.enqueue(writeLog("2026-01-05", seconds: seconds)) }
        recorder.gate.signal()
        store.flush()
        #expect(recorder.changes == ["write 2026-01-05 1", "write 2026-01-05 5"])
    }

    @Test func twoDaysInABurstBothSurvive() {
        // The midnight case: the old day's last save and the new day's first.
        let recorder = Recorder(hold: true)
        let store = ActivityDayStore(directory: tempDirectory(), perform: { recorder.perform($0) })
        store.enqueue(writeLog("2026-01-05", seconds: 1))
        #expect(recorder.started.wait(timeout: .now() + 10) == .success)
        store.enqueue(writeLog("2026-01-05", seconds: 2))
        store.enqueue(writeLog("2026-01-06", seconds: 3))
        store.enqueue(writeLog("2026-01-05", seconds: 4))
        store.enqueue(writeLog("2026-01-06", seconds: 5))
        recorder.gate.signal()
        store.flush()
        let changes = recorder.changes
        #expect(changes.count == 3)
        #expect(changes.first == "write 2026-01-05 1")
        #expect(changes.filter { $0.hasPrefix("write 2026-01-05") }.last == "write 2026-01-05 4")
        #expect(changes.filter { $0.hasPrefix("write 2026-01-06") } == ["write 2026-01-06 5"])
    }

    @Test func aChangeBetweenTwoWritesOfADayKeepsTheirOrder() {
        let recorder = Recorder(hold: true)
        let store = ActivityDayStore(directory: tempDirectory(), perform: { recorder.perform($0) })
        store.enqueue(writeLog("2026-01-05", seconds: 1))
        #expect(recorder.started.wait(timeout: .now() + 10) == .success)
        store.enqueue(writeLog("2026-01-05", seconds: 2))
        store.enqueue(.removeTitles)
        store.enqueue(writeLog("2026-01-05", seconds: 3))
        recorder.gate.signal()
        store.flush()
        #expect(recorder.changes == ["write 2026-01-05 1", "write 2026-01-05 2", "removeTitles", "write 2026-01-05 3"])
    }

    @Test func daysLoadOldestFirstAndSkipMissingOnes() async {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ActivityDayStore(directory: dir)
        store.enqueue(writeLog("2026-01-10", seconds: 10))
        store.enqueue(writeLog("2026-01-01", seconds: 10))
        let days = await store.load(days: ["2026-01-10", "2026-01-05", "2026-01-01"])
        #expect(days.map(\.day) == ["2026-01-01", "2026-01-10"])
        #expect(await store.load(days: []).isEmpty)
    }

    @Test func hasTitlesIsFalseWithNoFolderAndTrueOnceANameIsStored() async {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ActivityDayStore(directory: dir)
        #expect(!(await store.hasTitles()))
        store.enqueue(.write(dayLog("2026-01-05", [seg(0, 10)])))
        #expect(!(await store.hasTitles()))
        store.enqueue(.write(dayLog("2026-01-06", [seg(0, 10, title: "Named")])))
        #expect(await store.hasTitles())
    }

    @Test func aCorruptFileLoadsAsNilWithoutThrowing() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ActivityDayStore(directory: dir)
        store.enqueue(writeLog("2026-01-02", seconds: 10))
        store.flush()
        try Data("{not json".utf8).write(to: store.url(for: "2026-01-01"))
        try Data("{\"day\": 5}".utf8).write(to: store.url(for: "2026-01-03"))
        try Data().write(to: store.url(for: "2026-01-04"))

        #expect(store.load(day: "2026-01-01") == nil)
        #expect(store.load(day: "2026-01-03") == nil)
        #expect(store.load(day: "2026-01-04") == nil)
        let days = await store.load(days: ["2026-01-01", "2026-01-02", "2026-01-03", "2026-01-04"])
        #expect(days.map(\.day) == ["2026-01-02"])
        #expect(!(await store.hasTitles()))

        // Maintenance passes step over it.
        store.enqueue(.removeTitles)
        store.enqueue(.remove(apps: ["com.a"]))
        store.flush()
        #expect(FileManager.default.fileExists(atPath: store.url(for: "2026-01-01").path))
    }

    @Test func loadingStripsAnythingUnsafeAFileHolds() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ActivityDayStore(directory: dir)
        var log = ActivityDayLog(day: "2026-01-05")
        log.totals = [FocusActivity(appID: "a", appName: "A", site: "https://x.y/z", seconds: 5),
                      FocusActivity(appID: "a", appName: "A", site: "nature.com", seconds: 0)]
        log.stretches = [seg(0, 10, site: "https://x.y/z")]
        try ActivityDayStore.encode(log).write(to: store.url(for: "2026-01-05"))

        let loaded = try #require(store.load(day: "2026-01-05"))
        #expect(loaded.totals.count == 1)
        #expect(loaded.totals[0].site == nil)
        #expect(loaded.stretches.map(\.site) == [nil])
    }

    @Test func dayKeysHaveOneExactShape() {
        #expect(ActivityDayStore.isDayKey("2026-01-05"))
        for key in ["2026-1-05", "2026/01/05", "20260105", "abcd-ef-gh", "2026-01-05x", "", "2026-01-05.json"] {
            #expect(!ActivityDayStore.isDayKey(key), "\(key)")
        }
    }
}
