import AppKit
import Foundation
import Testing
@testable import Nidus

/// A browser that answers Apple Events from a script, and remembers what it was asked.
private final class FakeBrowser: AppleEventSending, @unchecked Sendable {
    /// The property each event asked for, `pALL` for the combined read.
    private(set) var asked: [String] = []
    private(set) var timeouts: [TimeInterval] = []
    var url: String? = "https://example.com/page"
    var name = "Example page"
    /// How a `properties` read ends: a record, an error, or an empty answer.
    var combined: Result<Bool, AppleEventError> = .success(true)
    var failEverything: AppleEventError?
    /// The address a second read sees, for a tab changed in between.
    var laterURL: String?
    private var urlReads = 0

    func get(_ specifier: NSAppleEventDescriptor, timeout: TimeInterval) throws(AppleEventError) -> NSAppleEventDescriptor {
        let code = specifier.paramDescriptor(forKeyword: fourCC("seld"))?.typeCodeValue ?? 0
        let property = Self.name(of: code)
        asked.append(property)
        timeouts.append(timeout)
        if let failEverything { throw failEverything }
        switch property {
        case "pALL":
            switch combined {
            case .failure(let error): throw error
            case .success(let usable):
                guard usable, let url else { return NSAppleEventDescriptor(string: "") }
                let record = NSAppleEventDescriptor.record()
                record.setDescriptor(NSAppleEventDescriptor(string: url), forKeyword: fourCC("URL "))
                record.setDescriptor(NSAppleEventDescriptor(string: name), forKeyword: fourCC("pnam"))
                return record
            }
        case "pnam":
            return NSAppleEventDescriptor(string: name)
        default:
            urlReads += 1
            guard let url else { throw .failed(-10000) }
            return NSAppleEventDescriptor(string: urlReads > 1 ? (laterURL ?? url) : url)
        }
    }

    private static func name(of code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> UInt32($0)) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct TabReadTests {
    @Test func aChromiumTabIsReadWithOneEvent() {
        let browser = FakeBrowser()
        let detail = ActivityProbe.readTab(in: .chrome, using: browser, titles: true)
        #expect(browser.asked == ["pALL"])
        #expect(browser.timeouts == [0.75])
        #expect(detail?.title == "Example page")
        #expect(detail?.domain == "example.com")
        #expect(detail?.url == "https://example.com/page")
    }

    @Test func everyChromiumProfileKeepsItsOwnAddressCode() {
        for profile in [BrowserProfile.chrome, .brave, .chromium, .operaAir] {
            let browser = FakeBrowser()
            #expect(ActivityProbe.readTab(in: profile, using: browser, titles: true)?.title == "Example page", "\(profile.name)")
            #expect(browser.asked.count == 1, "\(profile.name)")
        }
    }

    @Test func withTitlesOffOnlyTheAddressIsAskedFor() {
        let browser = FakeBrowser()
        let detail = ActivityProbe.readTab(in: .chrome, using: browser, titles: false)
        #expect(browser.asked == ["URL "], "One event, and the title is never requested")
        #expect(detail?.title == nil)
        #expect(detail?.domain == "example.com")
    }

    @Test func safariStillReadsAddressTitleAndAddressAgain() {
        let browser = FakeBrowser()
        let detail = ActivityProbe.readTab(in: .safari, using: browser, titles: true)
        #expect(browser.asked == ["pURL", "pnam", "pURL"])
        #expect(detail?.title == "Example page")
    }

    @Test func safariWithTitlesOffIsOneEvent() {
        let browser = FakeBrowser()
        #expect(ActivityProbe.readTab(in: .safari, using: browser, titles: false)?.title == nil)
        #expect(browser.asked == ["pURL"])
    }

    @Test func safariDropsATabThatChangedBetweenReads() {
        let browser = FakeBrowser()
        browser.laterURL = "https://other.example/"
        #expect(ActivityProbe.readTab(in: .safari, using: browser, titles: true) == nil)
    }

    @Test func aTimeoutIsOneEventAndNoRead() {
        let browser = FakeBrowser()
        browser.combined = .failure(.timedOut)
        #expect(ActivityProbe.readTab(in: .chrome, using: browser, titles: true) == nil)
        #expect(browser.asked == ["pALL"], "A slow browser is not asked again")
        #expect(browser.timeouts == [0.75])
    }

    @Test func aRefusedReadIsNotRetried() {
        let browser = FakeBrowser()
        browser.combined = .failure(.notPermitted)
        #expect(ActivityProbe.readTab(in: .chrome, using: browser, titles: true) == nil)
        #expect(browser.asked == ["pALL"])
    }

    @Test func aBrowserThatCannotAnswerTogetherFallsBackToTheOldReads() {
        for combined in [Result<Bool, AppleEventError>.failure(.failed(-10000)), .success(false)] {
            let browser = FakeBrowser()
            browser.combined = combined
            let detail = ActivityProbe.readTab(in: .operaAir, using: browser, titles: true)
            #expect(browser.asked == ["pALL", "URL ", "pnam", "URL "])
            #expect(detail?.title == "Example page")
        }
    }

    @Test func aWindowThatCannotBeReadKeepsNothing() {
        // A private window answers neither way, so nothing is recorded for it.
        for profile in [BrowserProfile.chrome, .safari] {
            let browser = FakeBrowser()
            browser.failEverything = .failed(-10000)
            #expect(ActivityProbe.readTab(in: profile, using: browser, titles: true) == nil, "\(profile.name)")
            #expect(ActivityProbe.readTab(in: profile, using: browser, titles: false) == nil, "\(profile.name)")
        }
    }

    @Test func aTitleNamingAnAddressIsStillDropped() {
        let browser = FakeBrowser()
        browser.name = "https://example.com/secret"
        #expect(ActivityProbe.readTab(in: .chrome, using: browser, titles: true)?.title == nil)
    }
}
