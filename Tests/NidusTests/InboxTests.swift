//
//  InboxTests.swift
//  NidusTests
//
//  The distraction inbox: what it keeps and drops, when a repeat adds nothing,
//  how long things stay, what a save link may and may not do, and the block
//  page's Save for later. Temporary folders and a clock moved by hand; nothing
//  reads the real inbox, opens a URL, or registers a real hot key.
//

import Foundation
import JavaScriptCore
import Testing
@testable import Nidus

/// A folder of its own, an inbox on it, and a clock the test moves.
@MainActor
final class InboxFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-inbox-\(UUID().uuidString)")
    let clock = TestClock()
    private(set) var inbox: FocusInbox!

    init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        inbox = makeInbox()
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func makeInbox() -> FocusInbox {
        let clock = clock
        return FocusInbox(directory: directory, now: { clock.now })
    }

    /// A second inbox on the same folder: Nidus relaunching.
    func reload() { inbox = makeInbox() }

    var file: URL { directory.appendingPathComponent(FocusInbox.fileName) }
}

private let day: TimeInterval = 24 * 60 * 60

// MARK: - Capturing

@MainActor
struct InboxCaptureTests {
    @Test func aThoughtIsKept() throws {
        let f = InboxFixture()
        guard case .added(let item, let dropped) = f.inbox.add(text: "Email Dana") else { Issue.record("not added"); return }
        #expect(item.text == "Email Dana")
        #expect(item.url == nil)
        #expect(item.source == .capture)
        #expect(item.createdAt == f.clock.now)
        #expect(item.completedAt == nil)
        #expect(!dropped)
        #expect(f.inbox.openCount == 1)
    }

    @Test func wordsAreTrimmedAndOnOneLine() {
        let f = InboxFixture()
        f.inbox.add(text: "  \n Call the core\nabout the sort\t slot \n ")
        #expect(f.inbox.items.first?.text == "Call the core about the sort  slot")
    }

    @Test func wordsStopAt280Characters() {
        let f = InboxFixture()
        f.inbox.add(text: String(repeating: "a", count: 500))
        #expect(f.inbox.items.first?.text.count == 280)
        // Counted in characters, not bytes: an emoji is one.
        f.inbox.add(text: String(repeating: "\u{1F9EC}", count: 300))
        #expect(f.inbox.items.last?.text.count == 280)
        // Trimmed again after the cut, so it never ends in a space.
        f.inbox.add(text: String(repeating: "a", count: 279) + " tail")
        #expect(f.inbox.items.last?.text == String(repeating: "a", count: 279))
    }

    @Test func nothingToSaveIsRefused() {
        let f = InboxFixture()
        #expect(f.inbox.add(text: "   \n ") == .empty)
        #expect(f.inbox.add(text: "", link: "") == .empty)
        // Not an address Nidus keeps, and no words: nothing left.
        #expect(f.inbox.add(text: "", link: "javascript:alert(1)") == .empty)
        #expect(f.inbox.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.file.path), "nothing saved, nothing written")
    }

    @Test func aLinkAloneIsNamedForItsSite() throws {
        let f = InboxFixture()
        guard case .added(let item, _) = f.inbox.add(text: "", link: "https://www.Example.com/a/b?x=1") else {
            Issue.record("not added")
            return
        }
        #expect(item.text == "example.com")
        #expect(item.url == "https://www.example.com/a/b?x=1")
    }

    @Test func aLinkThatIsNotAWebAddressIsDroppedAndTheWordsKept() {
        let f = InboxFixture()
        for link in ["javascript:alert(document.cookie)", "data:text/html,<script>1</script>", "file:///etc/passwd",
                     "ftp://example.com/x", "mailto:a@example.com", "chrome://settings", "vbscript:x", "nidus://end"] {
            guard case .added(let item, let dropped) = f.inbox.add(text: "Look at this", link: link) else {
                Issue.record("not added: \(link)")
                continue
            }
            #expect(item.url == nil, "\(link) was kept")
            #expect(item.text == "Look at this")
            #expect(dropped)
        }
    }

    @Test func anItemIsNeverBlankOrOversizedWhateverTheFileSays() throws {
        // A hand-edited file: the same cleaning applies on the way back in.
        let f = InboxFixture()
        let id = UUID().uuidString
        let long = String(repeating: "x", count: 900)
        let json = """
        {"version":1,"items":[
          {"id":"\(id)","text":"\(long)","url":"javascript:alert(1)","source":"capture","createdAt":10}
        ]}
        """
        try json.write(to: f.file, atomically: true, encoding: .utf8)
        f.reload()
        let item = try #require(f.inbox.items.first)
        #expect(item.text.count == 280)
        #expect(item.url == nil)
    }
}

// MARK: - Addresses

struct InboxURLTests {
    @Test(arguments: [
        "javascript:alert(1)", "JavaScript:alert(1)", "data:text/html;base64,PHNjcmlwdD4=", "file:///Users/x/secrets.txt",
        "ftp://example.com/", "mailto:someone@example.com", "tel:5551234", "chrome://settings", "about:blank",
        "x-apple.systempreferences:com.apple.preference.security", "nidus://end", "blob:null/uuid", "view-source:example.com",
        "https:example.com", "http:/example.com", "https://", "https:///nohost", "http://",
    ])
    func unsafeOrBrokenSchemesAreRefused(_ text: String) {
        #expect(InboxURL.clean(text) == nil, "\(text) was accepted")
        #expect(InboxURL.clean(text, assumingHTTPS: true) == nil, "\(text) was accepted when typed")
    }

    @Test func aMissingSchemeIsRefusedFromALinkAndFilledInForTypedText() {
        #expect(InboxURL.clean("example.com/page") == nil)
        #expect(InboxURL.clean("example.com/page", assumingHTTPS: true) == "https://example.com/page")
        #expect(InboxURL.clean("//example.com/page", assumingHTTPS: true) == "https://example.com/page")
        #expect(InboxURL.clean("localhost:3000/app", assumingHTTPS: true) == "https://localhost:3000/app")
        // Words are not an address.
        #expect(InboxURL.clean("remember the milk", assumingHTTPS: true) == nil)
        #expect(InboxURL.clean("milk", assumingHTTPS: true) == nil)
    }

    @Test func httpAndHttpsAreKeptInCanonicalForm() {
        #expect(InboxURL.clean("https://example.com/a?b=1#c") == "https://example.com/a?b=1#c")
        #expect(InboxURL.clean("  HTTP://EXAMPLE.COM/Path  ") == "http://example.com/Path", "scheme and host fold, the path does not")
        #expect(InboxURL.clean("https://example.com.") == "https://example.com")
        #expect(InboxURL.clean("http://localhost:8080/x") == "http://localhost:8080/x")
        #expect(InboxURL.clean("http://[::1]:80/") != nil)
    }

    @Test func spacesAndUnicodeAreEncoded() {
        #expect(InboxURL.clean("https://example.com/a b?q=x y") == "https://example.com/a%20b?q=x%20y")
        #expect(InboxURL.clean("https://example.com/caf\u{00E9}") == "https://example.com/caf%C3%A9")
        #expect(InboxURL.clean("https://b\u{00FC}cher.de/") == "https://xn--bcher-kva.de/")
        // Already encoded is left alone, not encoded twice.
        #expect(InboxURL.clean("https://example.com/a%20b") == "https://example.com/a%20b")
    }

    @Test func credentialsBadPortsAndControlCharactersAreRefused() {
        #expect(InboxURL.clean("https://user:pass@example.com/") == nil)
        #expect(InboxURL.clean("https://user@example.com/") == nil)
        #expect(InboxURL.clean("https://example.com:0/") == nil)
        #expect(InboxURL.clean("https://example.com:99999/") == nil)
        #expect(InboxURL.clean("https://example.com/\u{0000}") == nil)
        #expect(InboxURL.clean("https://example.com/a\nb") == nil)
        #expect(InboxURL.clean("") == nil)
        #expect(InboxURL.clean("   ") == nil)
        #expect(InboxURL.clean("https://example.com/" + String(repeating: "a", count: InboxURL.limit)) == nil)
    }

    @Test func theSamePageHasOneKey() {
        let same = [
            "https://example.com/a", "http://example.com/a", "https://www.example.com/a/", "HTTPS://EXAMPLE.COM/a#section",
            "https://example.com:443/a", "https://example.com/a#", "https://example.com./a",
        ]
        let keys = same.map { InboxURL.key(for: $0) }
        #expect(Set(keys).count == 1, "\(keys)")
        #expect(keys.first! != nil)
    }

    @Test func differentPagesHaveDifferentKeys() {
        let keys = ["https://example.com/a", "https://example.com/b", "https://example.com/a?x=1", "https://example.org/a",
                    "https://example.com:8443/a", "https://sub.example.com/a", "https://example.com/A"]
        #expect(Set(keys.map { InboxURL.key(for: $0) }).count == keys.count)
        #expect(InboxURL.key(for: "javascript:1") == nil)
        #expect(InboxURL.key(for: "https://example.com/%7Euser") == InboxURL.key(for: "https://example.com/~user"))
    }
}

// MARK: - Repeats

@MainActor
struct InboxDuplicateTests {
    private let page = "https://example.com/paper"

    @Test func theSamePageWithinTenMinutesAddsNothing() {
        let f = InboxFixture()
        guard case .added(let first, _) = f.inbox.add(text: "", link: page, source: .blockedPage) else { Issue.record("not added"); return }
        f.clock.advance(9 * 60)
        #expect(f.inbox.add(text: "", link: page, source: .blockedPage) == .duplicate(first))
        // However it is written.
        #expect(f.inbox.add(text: "", link: "http://www.example.com/paper/#top", source: .blockedPage) == .duplicate(first))
        #expect(f.inbox.items.count == 1)
    }

    @Test func anOpenItemWithTheSamePageBlocksARepeatAtAnyAge() {
        let f = InboxFixture()
        f.inbox.add(text: "", link: page)
        f.clock.advance(40 * day)
        guard case .duplicate = f.inbox.add(text: "again", link: page) else { Issue.record("added a repeat"); return }
        #expect(f.inbox.items.count == 1)
    }

    @Test func aRepeatFromTheCaptureBoxIsRefusedToo() {
        let f = InboxFixture()
        f.inbox.add(text: "first", link: "example.com/paper", assumingHTTPS: true)
        guard case .duplicate = f.inbox.add(text: "second", link: "https://example.com/paper", source: .capture) else {
            Issue.record("added a repeat")
            return
        }
    }

    @Test func afterCompletionARepeatIsRefusedUntilTenMinutesHavePassed() {
        let f = InboxFixture()
        guard case .added(let item, _) = f.inbox.add(text: "", link: page) else { Issue.record("not added"); return }
        f.inbox.setCompleted(item.id, true)
        f.clock.advance(5 * 60)
        guard case .duplicate = f.inbox.add(text: "", link: page) else { Issue.record("a reload re-added a finished item"); return }
        f.clock.advance(6 * 60)
        guard case .added = f.inbox.add(text: "", link: page) else { Issue.record("a deliberate save later was refused"); return }
        #expect(f.inbox.items.count == 2)
        #expect(f.inbox.openCount == 1)
    }

    @Test func aDeletedItemCanBeSavedAgain() {
        let f = InboxFixture()
        guard case .added(let item, _) = f.inbox.add(text: "", link: page) else { Issue.record("not added"); return }
        f.inbox.delete(item.id)
        guard case .added = f.inbox.add(text: "", link: page) else { Issue.record("refused after delete"); return }
    }

    @Test func wordsAloneAlwaysAdd() {
        let f = InboxFixture()
        f.inbox.add(text: "Email Dana")
        guard case .added = f.inbox.add(text: "Email Dana") else { Issue.record("refused words"); return }
        #expect(f.inbox.items.count == 2)
    }

    @Test func aDifferentPageIsNotARepeat() {
        let f = InboxFixture()
        f.inbox.add(text: "", link: page)
        guard case .added = f.inbox.add(text: "", link: "https://example.com/other") else { Issue.record("refused"); return }
    }
}

// MARK: - Changing and keeping

@MainActor
struct InboxLifecycleTests {
    @Test func completeUncompleteAndDelete() throws {
        let f = InboxFixture()
        f.inbox.add(text: "one")
        f.inbox.add(text: "two")
        let one = try #require(f.inbox.openItems.last)
        #expect(f.inbox.setCompleted(one.id, true))
        #expect(f.inbox.openCount == 1)
        #expect(f.inbox.completedItems.map(\.text) == ["one"])
        #expect(f.inbox.item(one.id)?.completedAt == f.clock.now)
        #expect(f.inbox.setCompleted(one.id, false))
        #expect(f.inbox.openCount == 2)
        #expect(f.inbox.item(one.id)?.completedAt == nil)
        #expect(f.inbox.delete(one.id))
        #expect(f.inbox.items.map(\.text) == ["two"])
        #expect(!f.inbox.delete(one.id), "a second delete finds nothing")
        #expect(!f.inbox.setCompleted(UUID(), true))
    }

    @Test func openItemsAreNewestFirst() {
        let f = InboxFixture()
        f.inbox.add(text: "first")
        f.clock.advance(60)
        f.inbox.add(text: "second")
        f.clock.advance(60)
        f.inbox.add(text: "third")
        #expect(f.inbox.openItems.map(\.text) == ["third", "second", "first"])
    }

    @Test func clearRemovesEverythingAndTheFileButNotTheToken() throws {
        let f = InboxFixture()
        let token = try #require(InboxSaveToken.loadOrCreate(in: f.directory))
        let first = f.inbox.add(text: "one")
        f.inbox.add(text: "two")
        if case .added(let item, _) = first { f.inbox.setCompleted(item.id, true) }
        #expect(FileManager.default.fileExists(atPath: f.file.path))
        f.inbox.clear()
        #expect(f.inbox.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.file.path))
        #expect(InboxSaveToken.read(in: f.directory) == token, "the pages already up would stop working")
        f.reload()
        #expect(f.inbox.items.isEmpty)
    }

    @Test func itemsSurviveARelaunch() throws {
        let f = InboxFixture()
        f.inbox.add(text: "Email Dana")
        f.inbox.add(text: "Read this", link: "https://example.com/p")
        f.clock.advance(60)
        f.reload()
        #expect(f.inbox.items.count == 2)
        #expect(f.inbox.items.first(where: { $0.url != nil })?.url == "https://example.com/p")
        // Written whole: no half-written file or leftover temporary in the folder.
        let names = try FileManager.default.contentsOfDirectory(atPath: f.directory.path)
        #expect(names == [FocusInbox.fileName])
    }

    @Test func countsWhatWasSavedSinceAMoment() {
        let f = InboxFixture()
        f.inbox.add(text: "before")
        f.clock.advance(60)
        let start = f.clock.now
        f.clock.advance(60)
        f.inbox.add(text: "during one")
        f.inbox.add(text: "during two", link: "https://example.com/x")
        #expect(f.inbox.count(since: start) == 2)
        #expect(f.inbox.count(since: f.clock.now.addingTimeInterval(1)) == 0)
        #expect(f.inbox.count(since: .distantPast) == 3)
    }

    @Test func changesAreAnnounced() {
        let f = InboxFixture()
        var changes = 0
        f.inbox.onChange = { changes += 1 }
        f.inbox.add(text: "one")
        #expect(changes == 1)
        f.inbox.add(text: "   ")
        #expect(changes == 1, "nothing changed")
        if let id = f.inbox.items.first?.id {
            f.inbox.setCompleted(id, true)
            f.inbox.delete(id)
        }
        #expect(changes == 3)
    }
}

// MARK: - Retention

@MainActor
struct InboxRetentionTests {
    @Test func aCompletedItemGoesThirtyDaysAfterItWasCompleted() throws {
        let f = InboxFixture()
        guard case .added(let item, _) = f.inbox.add(text: "done soon") else { Issue.record("not added"); return }
        f.clock.advance(10 * day)
        f.inbox.setCompleted(item.id, true)
        f.clock.advance(29 * day + 23 * 3600)
        #expect(!f.inbox.prune())
        #expect(f.inbox.items.count == 1, "just under 30 days after it was completed")
        f.clock.advance(3600)
        #expect(f.inbox.prune())
        #expect(f.inbox.items.isEmpty)
    }

    @Test func anOpenItemStaysUntilItIsDeleted() {
        let f = InboxFixture()
        f.inbox.add(text: "still to do")
        f.clock.advance(400 * day)
        #expect(!f.inbox.prune())
        f.reload()
        #expect(f.inbox.openCount == 1)
    }

    @Test func itIsPrunedOnLoad() throws {
        let f = InboxFixture()
        guard case .added(let old, _) = f.inbox.add(text: "old and done") else { Issue.record("not added"); return }
        f.inbox.add(text: "old and open")
        f.inbox.setCompleted(old.id, true)
        guard case .added(let recent, _) = f.inbox.add(text: "recent and done") else { Issue.record("not added"); return }
        f.clock.advance(20 * day)
        f.inbox.setCompleted(recent.id, true)
        f.clock.advance(15 * day)
        // 35 days after the first was done, 15 after the second.
        f.reload()
        #expect(Set(f.inbox.items.map(\.text)) == ["old and open", "recent and done"])
        // And at rest: the file has let go of it too.
        let onDisk = try String(contentsOf: f.file, encoding: .utf8)
        #expect(!onDisk.contains("old and done"))
    }

    @Test func itIsPrunedOnSave() {
        let f = InboxFixture()
        guard case .added(let item, _) = f.inbox.add(text: "done") else { Issue.record("not added"); return }
        f.inbox.setCompleted(item.id, true)
        f.clock.advance(31 * day)
        f.inbox.add(text: "something new")
        #expect(f.inbox.items.map(\.text) == ["something new"])
    }

    @Test func reopeningAnItemRestartsNothingAndKeepsIt() {
        let f = InboxFixture()
        guard case .added(let item, _) = f.inbox.add(text: "changed my mind") else { Issue.record("not added"); return }
        f.inbox.setCompleted(item.id, true)
        f.clock.advance(20 * day)
        f.inbox.setCompleted(item.id, false)
        f.clock.advance(100 * day)
        f.inbox.prune()
        #expect(f.inbox.openCount == 1)
    }
}

// MARK: - A bad file

@MainActor
struct InboxFileTests {
    @Test func oneBadItemCostsOnlyItself() throws {
        let f = InboxFixture()
        let good = UUID().uuidString, alsoGood = UUID().uuidString
        let json = """
        {"version":1,"items":[
          {"id":"\(good)","text":"keep me","source":"capture","createdAt":799999000},
          {"id":"not-a-uuid","text":"bad id","createdAt":799999000},
          {"text":"no id","createdAt":799999000},
          {"id":"\(UUID().uuidString)","text":"no date"},
          {"id":"\(UUID().uuidString)","createdAt":799999000},
          42,
          "junk",
          null,
          {"id":"\(alsoGood)","text":"me too","url":"https://example.com/x","source":"blockedPage","createdAt":799999100,"completedAt":799999500}
        ]}
        """
        try json.write(to: f.file, atomically: true, encoding: .utf8)
        f.reload()
        #expect(Set(f.inbox.items.map(\.id.uuidString)) == [good, alsoGood])
        let second = try #require(f.inbox.item(UUID(uuidString: alsoGood)!))
        #expect(second.source == .blockedPage)
        #expect(second.isCompleted)
        // The next change writes the good ones back, and only those.
        f.inbox.add(text: "new")
        f.reload()
        #expect(f.inbox.items.count == 3)
    }

    @Test func anItemWithAMalformedFieldKeepsTheRest() throws {
        let f = InboxFixture()
        let id = UUID().uuidString
        let json = """
        {"version":1,"items":[
          {"id":"\(id)","text":"hello","url":12,"source":"from-the-future","createdAt":100,"completedAt":"yesterday"}
        ]}
        """
        try json.write(to: f.file, atomically: true, encoding: .utf8)
        f.reload()
        let item = try #require(f.inbox.items.first)
        #expect(item.text == "hello")
        #expect(item.url == nil)
        #expect(item.source == .capture)
        #expect(item.completedAt == nil)
    }

    @Test func aFileThatIsNotAnInboxIsPutAsideNotOverwritten() throws {
        let f = InboxFixture()
        try "this is not json".write(to: f.file, atomically: true, encoding: .utf8)
        f.reload()
        #expect(f.inbox.items.isEmpty)
        f.inbox.add(text: "first of the new")
        let names = try FileManager.default.contentsOfDirectory(atPath: f.directory.path)
        let aside = try #require(names.first { $0.hasPrefix("inbox.unreadable-") })
        #expect(try String(contentsOf: f.directory.appendingPathComponent(aside), encoding: .utf8) == "this is not json")
        #expect(names.contains(FocusInbox.fileName))
    }

    @Test func aMissingFileIsAnEmptyInbox() {
        let f = InboxFixture()
        #expect(f.inbox.items.isEmpty)
        #expect(f.inbox.openCount == 0)
        #expect(!FileManager.default.fileExists(atPath: f.file.path), "reading creates nothing")
    }

    @Test func aFileFromALaterVersionStillReads() throws {
        let f = InboxFixture()
        let json = """
        {"version":7,"extra":{"a":1},"items":[
          {"id":"\(UUID().uuidString)","text":"future","createdAt":1,"labels":["x"],"source":"capture"}
        ]}
        """
        try json.write(to: f.file, atomically: true, encoding: .utf8)
        f.reload()
        #expect(f.inbox.items.map(\.text) == ["future"])
    }
}

// MARK: - The token

@MainActor
struct InboxTokenTests {
    @Test func aTokenIsRandomStableAndPrivate() throws {
        let f = InboxFixture()
        let token = try #require(InboxSaveToken.loadOrCreate(in: f.directory))
        #expect(InboxSaveToken.isWellFormed(token))
        #expect(InboxSaveToken.loadOrCreate(in: f.directory) == token, "the same one every time it is asked for")
        let path = f.directory.appendingPathComponent(InboxSaveToken.fileName).path
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        let other = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(InboxSaveToken.loadOrCreate(in: other) != token, "each install has its own")
    }

    @Test func onlyTheRightTokenMatches() throws {
        let f = InboxFixture()
        let token = try #require(InboxSaveToken.loadOrCreate(in: f.directory))
        #expect(InboxSaveToken.matches(token, in: f.directory))
        #expect(!InboxSaveToken.matches("", in: f.directory))
        #expect(!InboxSaveToken.matches(String(token.dropLast()), in: f.directory))
        #expect(!InboxSaveToken.matches(token + "0", in: f.directory))
        #expect(!InboxSaveToken.matches(token.uppercased(), in: f.directory))
        #expect(!InboxSaveToken.matches(String(repeating: "0", count: 64), in: f.directory))
        let nowhere = f.directory.appendingPathComponent("nowhere")
        #expect(!InboxSaveToken.matches(token, in: nowhere), "no token on disk matches nothing")
    }

    @Test func aDamagedTokenFileIsReplaced() throws {
        let f = InboxFixture()
        let file = f.directory.appendingPathComponent(InboxSaveToken.fileName)
        try "not a token".write(to: file, atomically: true, encoding: .utf8)
        #expect(InboxSaveToken.read(in: f.directory) == nil)
        #expect(!InboxSaveToken.matches("not a token", in: f.directory))
        let token = try #require(InboxSaveToken.loadOrCreate(in: f.directory))
        #expect(InboxSaveToken.isWellFormed(token))
    }
}

// MARK: - The link

@MainActor
struct InboxSaveLinkTests {
    private let goodToken = String(repeating: "ab", count: 32)

    private func link(_ page: String, token: String? = nil, extra: String = "") -> URL {
        // Encoded the way the page encodes it, with encodeURIComponent.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        let u = page.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "nidus://save?u=\(u)&k=\(token ?? goodToken)\(extra)")!
    }

    @Test func theLinkParsesToAnAddressAndAToken() {
        let result = NidusLink.parse(link("https://example.com/a?b=1&c=2#d"))
        #expect(result == .success(.save(url: "https://example.com/a?b=1&c=2#d", token: goodToken)))
        #expect(NidusLink(url: link("http://example.com/")) != nil)
        // An escape in the address survives the trip.
        #expect(NidusLink.parse(URL(string: "nidus://save?u=https%3A%2F%2Fexample.com%2Fa%2520b&k=\(goodToken)")!)
                == .success(.save(url: "https://example.com/a%20b", token: goodToken)))
    }

    @Test(arguments: [
        "nidus://save", "nidus://save?u=", "nidus://save?k=\(String(repeating: "ab", count: 32))",
        "nidus://save?u=https%3A%2F%2Fexample.com%2F",
        "nidus://save?u=https%3A%2F%2Fexample.com%2F&k=",
        "nidus://save?u=https%3A%2F%2Fexample.com%2F&k=short",
        "nidus://save?u=https%3A%2F%2Fexample.com%2F&k=\(String(repeating: "zz", count: 32))",
        "nidus://save?u=javascript%3Aalert(1)&k=\(String(repeating: "ab", count: 32))",
        "nidus://save?u=file%3A%2F%2F%2Fetc%2Fpasswd&k=\(String(repeating: "ab", count: 32))",
        "nidus://save?u=data%3Atext%2Fhtml%2Chi&k=\(String(repeating: "ab", count: 32))",
        "nidus://save?u=example.com&k=\(String(repeating: "ab", count: 32))",
        "nidus://save?u=%FF&k=\(String(repeating: "ab", count: 32))",
    ])
    func aLinkMissingOrBreakingEitherPartIsRefused(_ text: String) throws {
        let result = NidusLink.parse(try #require(URL(string: text)))
        guard case .failure = result else { Issue.record("accepted \(text)"); return }
    }

    @Test func aRefusalNeverHoldsTheAddressOrTheToken() {
        let secret = "SECRETPAGE"
        for text in ["nidus://save?u=javascript%3A\(secret)&k=\(goodToken)",
                     "nidus://save?u=https%3A%2F%2Fexample.com%2F\(secret)&k=\(secret)"] {
            guard case .failure(let rejection) = NidusLink.parse(URL(string: text)!) else { continue }
            #expect(!rejection.description.contains(secret))
            #expect(!rejection.description.contains(goodToken))
        }
    }

    @Test func theStoreSavesOnlyWithTheRightToken() throws {
        let f = InboxFixture()
        let token = try #require(InboxSaveToken.loadOrCreate(in: f.directory))
        #expect(f.inbox.saveFromBlockPage(url: "https://example.com/x", token: String(repeating: "0", count: 64)) == .badToken)
        #expect(f.inbox.saveFromBlockPage(url: "https://example.com/x", token: "") == .badToken)
        #expect(f.inbox.items.isEmpty, "a link without the token adds nothing")
        #expect(f.inbox.saveFromBlockPage(url: "https://example.com/x", token: token) == .saved)
        #expect(f.inbox.items.first?.source == .blockedPage)
        #expect(f.inbox.items.first?.url == "https://example.com/x")
        #expect(f.inbox.items.first?.text == "example.com")
        #expect(f.inbox.saveFromBlockPage(url: "https://example.com/x", token: token) == .duplicate)
        #expect(f.inbox.saveFromBlockPage(url: "javascript:alert(1)", token: token) == .notAWebAddress)
        #expect(f.inbox.items.count == 1)
    }

    @Test func withNoTokenOnDiskNothingIsSaved() {
        let f = InboxFixture()
        #expect(f.inbox.saveFromBlockPage(url: "https://example.com/x", token: String(repeating: "ab", count: 32)) == .badToken)
        #expect(f.inbox.items.isEmpty)
    }
}

// MARK: - Routing: a save link touches the inbox and nothing else

@MainActor
struct InboxRoutingTests {
    private final class Opened { var urls: [URL] = [] }

    private func saveLink(_ page: String, token: String) -> URL {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        let u = page.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "nidus://save?u=\(u)&k=\(token)")!
    }

    @Test func aSaveLinkSavesAndOpensNothing() throws {
        let f = InboxFixture()
        let token = try #require(InboxSaveToken.loadOrCreate(in: f.directory))
        let model = NidusModel()
        let opened = Opened()
        model.inbox = f.inbox
        model.inboxURLOpener = { opened.urls.append($0) }

        model.handle(saveLink("https://example.com/paper", token: token))
        #expect(f.inbox.items.map(\.url) == ["https://example.com/paper"])
        #expect(opened.urls.isEmpty, "saving never opens or navigates to the address")
        #expect(!model.isActive)
        #expect(model.cards.snoozeWait == nil)
    }

    @Test func aLinkWithoutTheTokenDoesNothing() throws {
        let f = InboxFixture()
        _ = try #require(InboxSaveToken.loadOrCreate(in: f.directory))
        let model = NidusModel()
        let opened = Opened()
        model.inbox = f.inbox
        model.inboxURLOpener = { opened.urls.append($0) }

        model.handle(URL(string: "nidus://save?u=https%3A%2F%2Fexample.com%2F")!)
        model.handle(saveLink("https://example.com/", token: String(repeating: "0", count: 64)))
        model.handle(saveLink("https://example.com/", token: "wrong"))
        #expect(f.inbox.items.isEmpty)
        #expect(opened.urls.isEmpty)
    }

    @Test func savingDuringAStrictSessionLoosensNothing() throws {
        let f = InboxFixture()
        let token = try #require(InboxSaveToken.loadOrCreate(in: f.directory))
        let model = NidusModel()
        let opened = Opened()
        model.inbox = f.inbox
        model.inboxURLOpener = { opened.urls.append($0) }

        // A strict session that blocks nothing, so no app or browser is touched.
        let sessionFolder = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-inbox-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sessionFolder) }
        let controller = FocusController(directory: sessionFolder)
        controller.start()
        defer { controller.stop() }
        model.adoptForTesting(controller: controller)
        controller.start(SessionPlan(goal: "Write", duration: 25 * 60, mode: .block, apps: [], websites: [], strict: true))
        let before = try #require(controller.engine.session)

        model.handle(saveLink("https://example.com/paper", token: token))
        model.handle(saveLink("https://example.com/paper", token: "bad"))

        #expect(f.inbox.items.count == 1)
        let after = try #require(controller.engine.session)
        #expect(after.plan == before.plan)
        #expect(after.plan.strict)
        #expect(after.snoozes.isEmpty, "nothing was snoozed, so nothing was let through")
        #expect(after.phase == before.phase, "not paused, shortened or ended")
        #expect(controller.engine.isRunning)
        #expect(opened.urls.isEmpty)
        #expect(model.cards.snoozeWait == nil)
    }

    @Test func theOpenButtonOpensOnlyThatItemsAddressAndOnlyWhenPressed() throws {
        let f = InboxFixture()
        let model = NidusModel()
        let opened = Opened()
        model.inbox = f.inbox
        model.inboxURLOpener = { opened.urls.append($0) }

        guard case .added(let link, _) = f.inbox.add(text: "paper", link: "https://example.com/paper"),
              case .added(let words, _) = f.inbox.add(text: "just words") else { Issue.record("not added"); return }
        #expect(opened.urls.isEmpty, "saving opened nothing")
        model.openInboxItem(words.id)
        #expect(opened.urls.isEmpty, "an item with no address has nothing to open")
        model.openInboxItem(UUID())
        #expect(opened.urls.isEmpty)
        model.openInboxItem(link.id)
        #expect(opened.urls.map(\.absoluteString) == ["https://example.com/paper"])
    }

    @Test func aTypedLinkInTheCaptureBoxGetsHTTPSAndAnUnsafeOneIsDropped() {
        let f = InboxFixture()
        let model = NidusModel()
        model.inbox = f.inbox
        model.saveToInbox(text: "read", link: "example.org/protocol")
        model.saveToInbox(text: "also", link: "javascript:alert(1)")
        #expect(f.inbox.items.map(\.url) == ["https://example.org/protocol", nil])
        #expect(model.saveToInbox(text: " ", link: "") == .empty)
    }

    @Test func theWrapUpCountsWhatWasSavedDuringTheSession() {
        let f = InboxFixture()
        let model = NidusModel()
        model.inbox = f.inbox
        f.inbox.add(text: "before the session")
        f.clock.advance(120)
        let start = f.clock.now
        f.clock.advance(60)
        f.inbox.add(text: "one")
        f.inbox.add(text: "two", link: "https://example.com/two", source: .blockedPage)
        #expect(model.savedForLater(since: start) == 2)
        #expect(NidusModel.savedForLaterText(2) == "2 saved for later")
        #expect(NidusModel.savedForLaterText(1) == "1 saved for later")
        #expect(NidusModel.savedForLaterText(0) == nil, "the card says nothing when nothing was saved")
        #expect(NidusModel().savedForLater(since: start) == 0, "no inbox, no count")
    }
}

// MARK: - The shortcut

@MainActor
private final class FakeRegistrar: HotKeyRegistrar {
    var registered: [KeyShortcut] = []
    var unregisterCalls = 0
    var accepts = true
    var handler: (@MainActor () -> Void)?

    func register(_ shortcut: KeyShortcut, handler: @escaping @MainActor () -> Void) -> Bool {
        guard accepts else { return false }
        registered.append(shortcut)
        self.handler = handler
        return true
    }

    func unregister() {
        unregisterCalls += 1
        handler = nil
    }

    var isLive: Bool { handler != nil }
}

@MainActor
struct InboxShortcutTests {
    private let control = KeyShortcut(keyCode: 49, modifiers: [.control, .option], key: "Space")!
    private let command = KeyShortcut(keyCode: 45, modifiers: [.command, .shift], key: "N")!

    @Test func aShortcutNeedsCommandControlOrOption() {
        #expect(KeyShortcut(keyCode: 0, modifiers: [], key: "A") == nil, "a bare key would be taken from every app")
        #expect(KeyShortcut(keyCode: 0, modifiers: [.shift], key: "A") == nil)
        #expect(KeyShortcut(keyCode: 0, modifiers: [.command], key: "A") != nil)
        #expect(KeyShortcut(keyCode: 0, modifiers: [.control], key: "A") != nil)
        #expect(KeyShortcut(keyCode: 0, modifiers: [.option], key: "A") != nil)
        #expect(KeyShortcut(keyCode: 0, modifiers: [.command], key: " ") == nil)
    }

    @Test func itIsWrittenTheWayTheMacWritesIt() {
        #expect(control.display == "\u{2303}\u{2325}Space")
        #expect(command.display == "\u{21E7}\u{2318}N")
        #expect(KeyShortcut(keyCode: 0, modifiers: [.command, .shift, .option, .control], key: "A")?.display
                == "\u{2303}\u{2325}\u{21E7}\u{2318}A")
        #expect(control.spoken == "Control Option Space")
        #expect(command.spoken == "Shift Command N")
    }

    @Test func keysAreNamedBySpecialNameOrByWhatTheyType() {
        #expect(KeyShortcut.name(forKeyCode: 49, characters: " ") == "Space")
        #expect(KeyShortcut.name(forKeyCode: 96, characters: nil) == "F5")
        #expect(KeyShortcut.name(forKeyCode: 123, characters: nil) == "\u{2190}")
        #expect(KeyShortcut.name(forKeyCode: 45, characters: "n") == "N")
        #expect(KeyShortcut.name(forKeyCode: 45, characters: "\u{00E9}") == "\u{00C9}")
        #expect(KeyShortcut.name(forKeyCode: 200, characters: nil) == nil)
        #expect(KeyShortcut.name(forKeyCode: 200, characters: "") == nil)
    }

    @Test func itRoundTripsAndABadOneDoesNotDecode() throws {
        let data = try JSONEncoder().encode(control)
        #expect(try JSONDecoder().decode(KeyShortcut.self, from: data) == control)
        let bare = Data(#"{"keyCode":0,"modifiers":0,"key":"A"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(KeyShortcut.self, from: bare) }
        // Off is stored as null and reads back as off.
        let off = try JSONEncoder().encode(KeyShortcut?.none)
        #expect(try JSONDecoder().decode(KeyShortcut?.self, from: off) == nil)
    }

    @Test func carbonModifiersMapTheFourKeys() {
        #expect(CarbonHotKeyRegistrar.carbonModifiers([.command]) == 256)
        #expect(CarbonHotKeyRegistrar.carbonModifiers([.shift]) == 512)
        #expect(CarbonHotKeyRegistrar.carbonModifiers([.option]) == 2048)
        #expect(CarbonHotKeyRegistrar.carbonModifiers([.control]) == 4096)
        #expect(CarbonHotKeyRegistrar.carbonModifiers([.command, .option]) == 256 + 2048)
    }

    @Test func offUntilSet() {
        let registrar = FakeRegistrar()
        let shortcut = CaptureShortcut(registrar: registrar) {}
        #expect(shortcut.current == nil)
        #expect(registrar.registered.isEmpty, "nothing registered until the person sets one")
        #expect(!shortcut.apply(nil))
        #expect(registrar.registered.isEmpty)
        #expect(!registrar.isLive)
    }

    @Test func settingRegistersAndAPressRunsTheHandler() {
        let registrar = FakeRegistrar()
        var presses = 0
        let shortcut = CaptureShortcut(registrar: registrar) { presses += 1 }
        #expect(shortcut.apply(control))
        #expect(registrar.registered == [control])
        #expect(shortcut.current == control)
        registrar.handler?()
        registrar.handler?()
        #expect(presses == 2)
    }

    @Test func changingReplacesAndClearingLetsGo() {
        let registrar = FakeRegistrar()
        let shortcut = CaptureShortcut(registrar: registrar) {}
        shortcut.apply(control)
        shortcut.apply(command)
        #expect(registrar.registered == [control, command])
        #expect(registrar.isLive)
        shortcut.apply(nil)
        #expect(!registrar.isLive, "cleared: nothing is registered")
        #expect(shortcut.current == nil)
    }

    @Test func aCombinationAnotherAppHasIsReported() {
        let registrar = FakeRegistrar()
        registrar.accepts = false
        let shortcut = CaptureShortcut(registrar: registrar) {}
        #expect(!shortcut.apply(control))
        #expect(shortcut.isRefused)
        #expect(shortcut.current == control, "what was asked for is still shown, with the problem")
        registrar.accepts = true
        #expect(shortcut.apply(command))
        #expect(!shortcut.isRefused)
    }

    @Test func quittingLetsGo() {
        let registrar = FakeRegistrar()
        let shortcut = CaptureShortcut(registrar: registrar) {}
        shortcut.apply(control)
        shortcut.stop()
        #expect(!registrar.isLive)
        #expect(shortcut.current == nil)
    }

    @Test func withoutAHostThereIsNoShortcut() {
        let model = NidusModel()
        #expect(model.captureShortcut == nil, "no host, no stored shortcut: off")
        #expect(!model.capture.shortcutIsRefused)
    }
}

// MARK: - Settings and the popover

@MainActor
struct InboxSurfaceTests {
    @Test func theInboxIsAPageInsideGeneralNotATab() {
        #expect(SettingsRoute.resolve(NidusModel.inboxPageID) == SettingsRoute(tab: .general, pushes: true))
        #expect(SettingsTab.allCases.map(\.rawValue) == ["general", "blocking", "setups", "schedules", "stats", "about"])
        let model = NidusModel()
        #expect(model.makeSettingsPage(id: NidusModel.inboxPageID) != nil)
    }

    @Test func theRowShowsOnlyWhenThereIsSomethingToSay() {
        #expect(!FocusInboxRow.isVisible(isActive: false, openCount: 0), "an idle popover with an empty inbox is as it was")
        #expect(FocusInboxRow.isVisible(isActive: true, openCount: 0), "Save a thought while a session runs")
        #expect(FocusInboxRow.isVisible(isActive: false, openCount: 3), "Inbox · 3 when items wait")
        #expect(FocusInboxRow.isVisible(isActive: true, openCount: 3))
    }

    @Test func openCountIgnoresFinishedItems() {
        let f = InboxFixture()
        let model = NidusModel()
        model.inbox = f.inbox
        #expect(model.inboxOpenCount == 0)
        f.inbox.add(text: "one")
        guard case .added(let two, _) = f.inbox.add(text: "two") else { Issue.record("not added"); return }
        #expect(model.inboxOpenCount == 2)
        f.inbox.setCompleted(two.id, true)
        #expect(model.inboxOpenCount == 1)
    }

    @Test func aRowReadsItsDateAndSource() {
        let item = InboxItem(text: "x", source: .blockedPage, createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        #expect(InboxItemRow.caption(for: item).hasPrefix("Block page \u{00B7} "))
        var done = item
        done.completedAt = Date(timeIntervalSinceReferenceDate: 800_000_100)
        #expect(InboxItemRow.caption(for: done).hasPrefix("Done "))
    }
}

// MARK: - The block page

@MainActor
struct BlockPageSaveTests {
    private func installed() throws -> (html: String, page: BlockPage, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-blockpage-\(UUID().uuidString)")
        let page = BlockPage(directory: folder)
        try page.install()
        return (try String(contentsOf: page.fileURL, encoding: .utf8), page, folder)
    }

    @Test func thePageCarriesTheInstallsTokenAndASaveLink() throws {
        let (html, _, folder) = try installed()
        defer { try? FileManager.default.removeItem(at: folder) }
        let token = try #require(InboxSaveToken.read(in: folder))
        #expect(html.contains("const token = \"\(token)\";"))
        #expect(!html.contains("{{TOKEN}}"))
        #expect(html.contains("id=\"save\""))
        #expect(html.contains("Save for later"))
        #expect(html.contains("\"nidus://save?u=\" + encodeURIComponent(q.get(\"u\")) + \"&k=\" + encodeURIComponent(token)"))
    }

    @Test func theTokenIsTheSameAfterAReinstall() throws {
        let (first, page, folder) = try installed()
        defer { try? FileManager.default.removeItem(at: folder) }
        try page.install()
        #expect(try String(contentsOf: page.fileURL, encoding: .utf8) == first, "pages already up stay valid")
    }

    @Test func theTokenIsNotInTheAddressOfABlockedTab() throws {
        let (_, page, folder) = try installed()
        defer { try? FileManager.default.removeItem(at: folder) }
        let token = try #require(InboxSaveToken.read(in: folder))
        let address = page.url(blocking: "https://example.com/a", goal: "Write", snoozeMinutes: 3, snoozeKey: "example.com")
        #expect(!address.contains(token), "it lives only in the page's file, which a web page can't read")
    }

    @Test func thePageWritesWithTextContentNeverMarkup() throws {
        let (html, _, folder) = try installed()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(html.contains("textContent"))
        for markup in ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function"] {
            #expect(!html.contains(markup), "the block page uses \(markup)")
        }
    }

    // MARK: The page's own script, run

    /// A page with a handful of stand-ins for the browser, enough to run the
    /// page's script. It reports what the script did to each element.
    private func run(query: String, withToken: Bool = true) throws -> (context: JSContext, elements: JSValue) {
        var (html, _, folder) = try installed()
        defer { try? FileManager.default.removeItem(at: folder) }
        if !withToken, let token = InboxSaveToken.read(in: folder) {
            html = html.replacingOccurrences(of: "const token = \"\(token)\";", with: "const token = \"\";")
        }
        let open = try #require(html.range(of: "<script>\n"))
        let close = try #require(html.range(of: "</script>"))
        let script = String(html[open.upperBound..<close.lowerBound])

        let context = try #require(JSContext())
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        context.evaluateScript("""
        var elements = {}, timers = [], usedMarkup = false;
        function Element(id) {
          this.id = id; this.hidden = true; this.href = null; this.textContent = ""; this.classes = []; this.attrs = {}; this.listeners = {};
          this.classList = { add: function (c) { this.owner.classes.push(c); }, owner: this };
          Object.defineProperty(this, "innerHTML", { set: function () { usedMarkup = true; } });
        }
        Element.prototype.setAttribute = function (k, v) { this.attrs[k] = v; };
        Element.prototype.removeAttribute = function (k) { if (k === "href") this.href = null; delete this.attrs[k]; };
        Element.prototype.addEventListener = function (type, fn) { this.listeners[type] = fn; };
        var document = { title: "", getElementById: function (id) { return elements[id] || (elements[id] = new Element(id)); } };
        var location = { search: \(literal(query)) };
        function setTimeout(fn) { timers.push(fn); }
        function URL(text) {
          var m = /^([a-z][a-z0-9+.-]*:)(?:\\/\\/([^\\/?#]*))?/i.exec(String(text));
          if (!m) throw new TypeError("Invalid URL");
          this.protocol = m[1].toLowerCase();
          this.hostname = (m[2] || "").replace(/^.*@/, "").replace(/:\\d+$/, "").toLowerCase();
        }
        function URLSearchParams(search) {
          this.values = {};
          var self = this;
          search.replace(/^\\?/, "").split("&").forEach(function (pair) {
            if (!pair) return;
            var i = pair.indexOf("=");
            var key = decodeURIComponent(i < 0 ? pair : pair.slice(0, i));
            var value = i < 0 ? "" : decodeURIComponent(pair.slice(i + 1).replace(/\\+/g, " "));
            if (!(key in self.values)) self.values[key] = value;
          });
        }
        URLSearchParams.prototype.get = function (key) { return key in this.values ? this.values[key] : null; };
        """)
        context.evaluateScript(script)
        #expect(failure == nil, "the page's script threw: \(failure ?? "")")
        return (context, try #require(context.objectForKeyedSubscript("elements")))
    }

    private func literal(_ text: String) -> String {
        let data = try? JSONEncoder().encode(text)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")) ?? ""
    }

    private func element(_ page: (context: JSContext, elements: JSValue), _ id: String) -> JSValue {
        page.elements.objectForKeyedSubscript(id)
    }

    /// The page's markup starts every one of these hidden, and the script
    /// reaches for an element only to show it, so one it never touched is hidden.
    private func isHidden(_ page: (context: JSContext, elements: JSValue), _ id: String) -> Bool {
        let value: JSValue = element(page, id)
        if value.isUndefined { return true }
        return value.objectForKeyedSubscript("hidden").toBool()
    }

    private func href(_ page: (context: JSContext, elements: JSValue), _ id: String) -> String? {
        let value: JSValue = element(page, id)
        if value.isUndefined { return nil }
        let href: JSValue = value.objectForKeyedSubscript("href")
        return href.isString ? href.toString() : nil
    }

    @Test func theSaveButtonShowsBesideSnooze() throws {
        let page = try run(query: "?g=Write&m=3&s=&u=\(encoded("https://www.example.com/a?b=1&c=2"))")
        let save = element(page, "save")
        #expect(save.objectForKeyedSubscript("hidden").toBool() == false)
        let href = try #require(save.objectForKeyedSubscript("href").toString())
        #expect(href.hasPrefix("nidus://save?u=\(encoded("https://www.example.com/a?b=1&c=2"))&k="))
        #expect(element(page, "snooze").objectForKeyedSubscript("hidden").toBool() == false)
        #expect(page.context.objectForKeyedSubscript("usedMarkup").toBool() == false)
    }

    @Test func aStrictSessionHasTheSaveButtonAndNoSnooze() throws {
        // m=0 is how the page is told it is strict.
        let page = try run(query: "?g=Write&m=0&s=&u=\(encoded("https://example.com/paper"))")
        #expect(isHidden(page, "snooze"))
        #expect(!isHidden(page, "save"))
        #expect(href(page, "save")?.hasPrefix("nidus://save?u=") == true)
        #expect(href(page, "snooze") == nil)
    }

    @Test func clickingSaysSavedAndSendsNoSecondLink() throws {
        let page = try run(query: "?g=&m=3&s=&u=\(encoded("https://example.com/paper"))")
        let save = element(page, "save")
        let listener = try #require(save.objectForKeyedSubscript("listeners").objectForKeyedSubscript("click"))
        listener.call(withArguments: [])
        #expect(save.objectForKeyedSubscript("textContent").toString() == "Saved for later")
        #expect(save.objectForKeyedSubscript("attrs").objectForKeyedSubscript("aria-disabled").toString() == "true")
        let status = element(page, "saved")
        #expect(status.objectForKeyedSubscript("hidden").toBool() == false)
        #expect(status.objectForKeyedSubscript("textContent").toString()?.hasPrefix("Saved for later") == true)
        // The link is followed first; only afterwards is it taken off.
        #expect(save.objectForKeyedSubscript("href").toString()?.hasPrefix("nidus://save") == true)
        let timers = try #require(page.context.objectForKeyedSubscript("timers"))
        timers.objectAtIndexedSubscript(0).call(withArguments: [])
        #expect(save.objectForKeyedSubscript("href").isNull)
        #expect(page.context.objectForKeyedSubscript("usedMarkup").toBool() == false)
    }

    @Test func aHostileAddressIsOnlyEverTextOrAnEncodedLinkParameter() throws {
        let hostile = "https://evil.example/<img src=x onerror=alert(1)>?\"'&k=forged"
        let page = try run(query: "?g=\(encoded("<b>bold</b>"))&m=3&s=\(encoded("<i>x</i>"))&u=\(encoded(hostile))")
        let href = try #require(element(page, "save").objectForKeyedSubscript("href").toString())
        // One `u` parameter, whole, and then the real `k`: the forged one sits inside u's encoding.
        #expect(href.contains("u=\(encoded(hostile))&k="))
        #expect(href.components(separatedBy: "&k=").count == 2)
        #expect(element(page, "goal-text").objectForKeyedSubscript("textContent").toString() == "<b>bold</b>")
        #expect(page.context.objectForKeyedSubscript("usedMarkup").toBool() == false)
    }

    @Test(arguments: ["file:///Users/x/secret.html", "ftp://example.com/x", "about:blank", "javascript:alert(1)", "not a url", ""])
    func thereIsNoSaveButtonForWhatIsNotAWebPage(_ address: String) throws {
        let page = try run(query: "?g=&m=3&s=&u=\(encoded(address))")
        #expect(isHidden(page, "save"), "\(address)")
        #expect(href(page, "save") == nil)
    }

    @Test func withoutATokenThereIsNoButton() throws {
        // A folder that could not hold the token file installs the page with
        // an empty one, and the page leaves its Save for later out.
        let page = try run(query: "?g=&m=3&s=&u=\(encoded("https://example.com/paper"))", withToken: false)
        #expect(isHidden(page, "save"))
        #expect(!isHidden(page, "snooze"), "Snooze is unaffected")
    }
}
