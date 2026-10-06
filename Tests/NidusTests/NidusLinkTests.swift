//
//  NidusLinkTests.swift
//  NidusTests
//
//  nidus:// links and the Shortcuts actions: how a link is read, which
//  session it asks for, and the one rule neither may bend: a strict session is
//  not ended from outside.
//

import Foundation
import Testing
@testable import Nidus

private func parse(_ text: String) -> Result<NidusLink, NidusLink.Rejection> {
    NidusLink.parse(URL(string: text)!)
}

/// The start parameters of a link that must parse.
private func start(_ query: String) throws -> NidusLink.Start {
    guard case .success(.start(let start)) = parse("nidus://start" + query) else {
        Issue.record("nidus://start\(query) did not parse as a start link")
        throw CancellationError()
    }
    return start
}

private func rejection(_ text: String) -> NidusLink.Rejection? {
    if case .failure(let why) = parse(text) { return why }
    return nil
}

// MARK: - Reading a link

struct NidusLinkParsingTests {
    @Test func theBlockPagesSnoozeLinkReadsAsBefore() {
        #expect(parse("nidus://snooze?site=youtube.com") == .success(.snooze(site: "youtube.com")))
        #expect(parse("nidus://snooze?site=youtube.com%2Fshorts") == .success(.snooze(site: "youtube.com/shorts")))
        // The block page writes it with encodeURIComponent. A full address is
        // cleaned to a rule as typing it in Settings would be: scheme, www.
        // and query go, the path stays, since a rule can name part of a site.
        #expect(parse("nidus://snooze?site=https%3A%2F%2Fwww.YouTube.com%2Fwatch%3Fv%3D1")
                == .success(.snooze(site: "youtube.com/watch")))
    }

    @Test(arguments: ["nidus://snooze", "nidus://snooze?site=", "nidus://snooze?site=localhost",
                      "nidus://snooze?other=youtube.com", "nidus://snooze?site=%FF"])
    func aSnoozeLinkWithoutAUsableSiteIsIgnored(_ text: String) {
        #expect(rejection(text) == .invalid(parameter: "site"))
    }

    @Test func theSimpleActionsTakeNothing() {
        #expect(parse("nidus://end") == .success(.end))
        #expect(parse("nidus://toggle") == .success(.toggle))
        #expect(parse("nidus://popover") == .success(.popover))
        // Whatever else the link carries is not theirs to read.
        #expect(parse("nidus://end/?minutes=abc&x=1") == .success(.end))
    }

    @Test func theActionNameIgnoresCase() {
        #expect(parse("NIDUS://End") == .success(.end))
        #expect(parse("nidus://TOGGLE") == .success(.toggle))
    }

    @Test(arguments: ["nidus://", "nidus://frobnicate", "nidus://start.example.com", "nidus:start?minutes=5",
                      "nidus://ending", "nidus://snooze.evil?site=youtube.com"])
    func anUnknownActionIsIgnored(_ text: String) {
        #expect(rejection(text) == .unknownAction)
    }

    @Test func aLinkOfAnotherSchemeIsNotOurs() {
        #expect(rejection("https://start?minutes=5") == .notNidus)
        #expect(rejection("focus://end") == .notNidus)
        #expect(NidusLink(url: URL(string: "droppy://end")!) == nil)
    }

    @Test func initReturnsNilForWhatParseRejects() {
        #expect(NidusLink(url: URL(string: "nidus://start?minutes=abc")!) == nil)
        #expect(NidusLink(url: URL(string: "nidus://end")!) == .end)
    }
}

struct NidusStartLinkTests {
    @Test func everyParameterIsOptional() throws {
        #expect(try start("") == NidusLink.Start())
        #expect(try start("?") == NidusLink.Start())
        #expect(try start("/") == NidusLink.Start())
    }

    @Test func aFullLinkReadsEveryParameter() throws {
        let link = try start("?goal=Write%20the%20post&minutes=45&categories=social,video&mode=allow&strict=1")
        #expect(link == NidusLink.Start(goal: "Write the post", minutes: 45, categories: ["social", "video"],
                                        mode: .allow, strict: true))
    }

    @Test func unknownParametersAreIgnored() throws {
        let link = try start("?minutes=10&utm_source=x&bad=%zz")
        #expect(link == NidusLink.Start(minutes: 10))
    }

    @Test func parameterNamesIgnoreCaseAndTheFirstOfARepeatWins() throws {
        #expect(try start("?MINUTES=15&Goal=Hi").minutes == 15)
        #expect(try start("?minutes=5&minutes=50").minutes == 5)
    }

    @Test func oneBadValueIgnoresTheWholeLink() {
        #expect(rejection("nidus://start?goal=Write&minutes=abc&mode=block") == .invalid(parameter: "minutes"))
        #expect(rejection("nidus://start?goal=Write&mode=sideways") == .invalid(parameter: "mode"))
        #expect(rejection("nidus://start?minutes=5&strict=maybe") == .invalid(parameter: "strict"))
    }

    @Test func aRejectionNamesTheParameterNeverItsValue() {
        let why = rejection("nidus://start?goal=my%20secret%20plan&minutes=soon")
        let text = why?.description ?? ""
        #expect(text == "invalid minutes")
        #expect(!text.contains("secret"))
    }

    // MARK: goal

    @Test func aGoalIsDecoded() throws {
        #expect(try start("?goal=Chapter%20three").goal == "Chapter three")
        #expect(try start("?goal=Read+the+paper").goal == "Read the paper", "a plus is a space, as a page building the link writes it")
        #expect(try start("?goal=C%2B%2B%20port").goal == "C++ port")
        #expect(try start("?goal=Q%26A%20%3D%20done").goal == "Q&A = done")
        #expect(try start("?goal=Caf%C3%A9%20%E2%80%94%20draft").goal == "Café — draft")
        #expect(try start("?goal=Ship%20it%20%F0%9F%9A%80").goal == "Ship it 🚀")
    }

    @Test func aGoalIsOneShortLine() throws {
        #expect(try start("?goal=%20%20padded%20%20").goal == "padded")
        #expect(try start("?goal=one%0Atwo%09three").goal == "one two three", "a newline would break the cards")
        let long = String(repeating: "a", count: 500)
        #expect(try start("?goal=\(long)").goal?.count == NidusLink.goalLimit)
    }

    @Test func anEmptyGoalIsKeptEmpty() throws {
        #expect(try start("?goal=").goal == "")
        #expect(try start("?goal").goal == "")
    }

    @Test(arguments: ["%FF", "%C3", "Caf%C3"])
    func aGoalThatIsNotValidUTF8IsIgnored(_ bad: String) {
        #expect(rejection("nidus://start?goal=\(bad)") == .invalid(parameter: "goal"))
    }

    @Test func aStrayPercentSignIsReadAsTyped() throws {
        // Foundation escapes a lone % when it makes the URL, so the link
        // arrives as %25 and a goal that says "50%" is not lost.
        #expect(try start("?goal=50%").goal == "50%")
        #expect(try start("?goal=%zz").goal == "%zz")
    }

    // MARK: minutes

    @Test(arguments: [("0", 0), ("1", 1), ("25", 25), ("90", 90), ("1440", 1440), ("007", 7), ("%2025%20", 25)])
    func minutesInRangeAreRead(_ text: String, _ minutes: Int) throws {
        #expect(try start("?minutes=\(text)").minutes == minutes)
    }

    @Test(arguments: ["1441", "9999", "-1", "-0", "%2B5", "2.5", "1e2", "0x10", "abc", "25min", "2%205", "99999999999999999999",
                      "%EF%BC%92%EF%BC%95", "%D9%A2%D9%A5"])
    func minutesOutOfRangeOrNotWholeAreIgnored(_ text: String) {
        #expect(rejection("nidus://start?minutes=\(text)") == .invalid(parameter: "minutes"))
    }

    @Test func emptyMinutesCountAsLeftOut() throws {
        #expect(try start("?minutes=&goal=Hi").minutes == nil)
        #expect(try start("?minutes").minutes == nil)
    }

    // MARK: categories

    @Test func categoriesAreSplitAndTrimmed() throws {
        #expect(try start("?categories=social,video").categories == ["social", "video"])
        #expect(try start("?categories=%20Social%20,%20Deep%20work%20").categories == ["Social", "Deep work"])
        #expect(try start("?categories=social%2Cvideo").categories == ["social", "video"])
        #expect(try start("?categories=social,,video,").categories == ["social", "video"])
    }

    @Test func noCategoriesAtAllCountAsLeftOut() throws {
        #expect(try start("?categories=").categories == nil)
        #expect(try start("?categories=,,%20,").categories == nil)
    }

    // MARK: mode and strict

    @Test(arguments: [("block", SessionPlan.Mode.block), ("allow", .allow), ("ALLOW", .allow), ("Block", .block)])
    func modeIsBlockOrAllow(_ text: String, _ mode: SessionPlan.Mode) throws {
        #expect(try start("?mode=\(text)").mode == mode)
    }

    @Test(arguments: ["deny", "both", "1", "blocklist"])
    func anyOtherModeIsIgnored(_ text: String) {
        #expect(rejection("nidus://start?mode=\(text)") == .invalid(parameter: "mode"))
    }

    @Test(arguments: [("1", true), ("true", true), ("YES", true), ("0", false), ("false", false), ("no", false)])
    func strictIsAYesOrNo(_ text: String, _ strict: Bool) throws {
        #expect(try start("?strict=\(text)").strict == strict)
    }

    @Test(arguments: ["2", "on", "strict", "-1"])
    func anyOtherStrictIsIgnored(_ text: String) {
        #expect(rejection("nidus://start?strict=\(text)") == .invalid(parameter: "strict"))
    }
}

// MARK: - The session a link asks for

struct NidusStartResolutionTests {
    let available = FocusCategory.presets + [
        FocusCategory(id: "7F3A-uuid", name: "Deep Work", symbol: "brain", apps: [], websites: ["reddit.com"]),
    ]

    private func resolved(_ start: NidusLink.Start) throws -> NidusLink.Start.Resolved {
        try start.resolve(against: available).get()
    }

    @Test func aLinkWithNothingInItTakesEverythingFromThePopoverAndSettings() throws {
        let result = try resolved(NidusLink.Start())
        #expect(result.request == SessionRequest(goal: "", minutes: nil, categoryIDs: nil, mode: nil, strict: nil))
        #expect(result.unmatched.isEmpty)
    }

    @Test func theGoalIsPassedThroughOrEmptyNeverNil() throws {
        #expect(try resolved(NidusLink.Start(goal: "Write")).request.goal == "Write")
        #expect(try resolved(NidusLink.Start()).request.goal == "", "nil would let a half-typed goal in")
    }

    @Test func minutesAndModeArePassedOn() throws {
        let request = try resolved(NidusLink.Start(minutes: 0, mode: .allow)).request
        #expect(request.minutes == 0, "0 is open-ended, not left out")
        #expect(request.mode == .allow)
    }

    @Test func categoriesMatchByIDOrNameAnyCase() throws {
        let request = try resolved(NidusLink.Start(categories: ["SOCIAL", "video", "deep work", "7f3a-UUID"])).request
        #expect(request.categoryIDs == ["social", "video", "7F3A-uuid"], "in the order asked, each once")
    }

    @Test func namesThatMatchNothingAreReportedAndTheRestStart() throws {
        let result = try resolved(NidusLink.Start(categories: ["social", "gaming", "Sports"]))
        #expect(result.request.categoryIDs == ["social"])
        #expect(result.unmatched == ["gaming", "Sports"])
    }

    @Test func ifNoneMatchNothingStarts() {
        let result = NidusLink.Start(categories: ["gaming", "sports"]).resolve(against: available)
        #expect(result == .failure(.init(asked: ["gaming", "sports"])))
        // Not the default pair: a link that said "gaming" meant gaming.
        #expect(NidusLink.Start(categories: ["social"]).resolve(against: []) == .failure(.init(asked: ["social"])))
    }

    @Test func aLinkCanMakeASessionStrictButNeverLessStrict() throws {
        #expect(try resolved(NidusLink.Start(strict: true)).request.strict == true)
        #expect(try resolved(NidusLink.Start(strict: false)).request.strict == nil, "Settings keeps its say")
        #expect(try resolved(NidusLink.Start()).request.strict == nil)
    }
}

// MARK: - Ending from outside

struct OutsideCommandTests {
    @Test func aStrictSessionIsNeverEndedFromOutside() {
        #expect(OutsideEnd(isActive: true, isStrict: true, isOnBreak: false) == .refusesStrict)
        // Whatever else is true of it.
        #expect(OutsideEnd(isActive: true, isStrict: true, isOnBreak: true) == .refusesStrict)
    }

    @Test func otherwiseItEndsWhatIsRunning() {
        #expect(OutsideEnd(isActive: true, isStrict: false, isOnBreak: false) == .endsSession)
        #expect(OutsideEnd(isActive: false, isStrict: false, isOnBreak: true) == .endsBreak)
        #expect(OutsideEnd(isActive: false, isStrict: false, isOnBreak: false) == .nothingRunning)
        // A strict flag with no session is a stale answer, not a lock.
        #expect(OutsideEnd(isActive: false, isStrict: true, isOnBreak: false) == .nothingRunning)
    }

    @Test func toggleSaysWhatItDid() {
        #expect(OutsideToggle(wasActive: true, wasStrict: false, isActive: false) == .ended)
        #expect(OutsideToggle(wasActive: true, wasStrict: true, isActive: true) == .refusedStrict)
        #expect(OutsideToggle(wasActive: false, wasStrict: false, isActive: true) == .started)
        #expect(OutsideToggle(wasActive: false, wasStrict: false, isActive: false) == .couldNotStart)
    }

    @Test func linksAndShortcutsEndOnlyThroughTheStrictCheck() throws {
        // The one place a session is ended from outside is `endFromOutside`,
        // which asks OutsideEnd first. A direct call elsewhere would skip it.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Nidus/App")
        for name in ["NidusLinkRouting.swift", "FocusIntents.swift", "NidusLink.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            for call in ["endSession(", "controller?.end(", "engine.end("] {
                #expect(!text.contains(call), "\(name) ends a session by \(call), around the strict check")
            }
        }
    }
}

// MARK: - Status

struct FocusStatusTests {
    private func running(_ seconds: TimeInterval, open: Bool = false) -> FocusStatus {
        FocusStatus(state: .running, isOpenEnded: open, isBlocking: true, remaining: seconds)
    }

    @Test func minutesLeftRoundUpAsTheCardsDo() {
        #expect(running(18 * 60).minutesLeft == 18)
        #expect(running(17 * 60 + 1).minutesLeft == 18)
        #expect(running(5).minutesLeft == 1)
        #expect(running(0).minutesLeft == 0)
        #expect(running(-3).minutesLeft == 0)
    }

    @Test func noMinutesWithoutATimedSession() {
        // Idle says nothing about open-ended or strict, whatever it's handed:
        // an idle app must never read as an open-ended session.
        let idle = FocusStatus(state: .idle, isOpenEnded: true, isStrict: true, remaining: 600)
        #expect(!idle.isOn && !idle.isOpenEnded && !idle.isStrict && idle.minutesLeft == nil)
        let open = running(0, open: true)
        #expect(open.isOn && open.isOpenEnded && open.minutesLeft == nil && open.endsAt == nil)
    }

    @Test func pausedIsOnButNotFocusing() {
        let paused = FocusStatus(state: .paused, remaining: 600)
        #expect(paused.isOn && !paused.isBlocking)
        #expect(paused.minutesLeft == 10)
        #expect(paused.endsAt == nil, "a paused clock has no end time")
    }

    @Test func aBreakHasItsOwnTimeAndIsNotASession() {
        let pause = FocusStatus(state: .onBreak, isOpenEnded: true, remaining: 240)
        #expect(!pause.isOn && !pause.isOpenEnded && pause.minutesLeft == 4)
        #expect(pause.endsAt == pause.observedAt.addingTimeInterval(240))
    }

    @Test func itSaysItInPlainWords() {
        #expect(FocusStatus(state: .idle).sentence == "Focus is off.")
        #expect(running(0, open: true).sentence == "Focus is on, open-ended.")
        #expect(running(18 * 60).sentence == "Focus is on, 18 minutes left.")
        #expect(running(30).sentence == "Focus is on, 1 minute left.")
        #expect(running(90 * 60).sentence == "Focus is on, 1 hour 30 minutes left.")
        #expect(FocusStatus(state: .paused, remaining: 600).sentence == "Focus is paused, 10 minutes left.")
        #expect(FocusStatus(state: .paused, isBlocking: true, remaining: 600).sentence
                == "Focus is paused while your Mac is locked, 10 minutes left. Blocking stays on.")
        #expect(FocusStatus(state: .onBreak, remaining: 240).sentence == "On a break, 4 minutes left.")
    }
}

// MARK: - Shortcuts

@MainActor
struct ShortcutsActionTests {
    @Test func theStrictRefusalIsInPlainWords() {
        #expect(String(localized: FocusIntentError.strict.localizedStringResource)
                == "This is a strict session. End it from the menu bar.")
    }

    @Test func noRunningAppMeansTheActionWaitsThenSaysNotReady() async {
        // Tests never set NidusModel.running, as a demo or render run does not.
        #expect(NidusModel.running == nil)
        #expect(await NidusModel.waitUntilRunning(timeout: .milliseconds(50)) == nil)
        await #expect(throws: FocusIntentError.notReady) { _ = try await NidusModel.forIntent(timeout: .milliseconds(50)) }
    }

    @Test func everyActionButTheJSONOneHasPhrases() {
        // The phrases themselves (each must say the app's name) are checked
        // by appintentsmetadataprocessor, which Scripts/appintents-metadata.sh
        // runs. Apple doesn't offer App Shortcuts on macOS; the actions are
        // in Shortcuts either way.
        #expect(NidusShortcuts.appShortcuts.count == 5)
    }

    @Test func theMinutesOfAnActionShareTheLinksRange() {
        #expect(NidusLink.minutesRange == 0...1440)
    }
}

// MARK: - A saved setup by name

struct NidusLinkPresetTests {
    @Test func aPresetIsReadByNameAndKeptOnOneLine() throws {
        #expect(try start("?preset=Deep%20work").preset == "Deep work")
        #expect(try start("?preset=Deep+work&minutes=50").preset == "Deep work")
        #expect(try start("?preset=Deep%0Awork").preset == "Deep work")
    }

    @Test func noPresetIsNil() throws {
        #expect(try start("?goal=Write").preset == nil)
        #expect(try start("?preset=").preset == nil)
    }

    @Test func aBlankPresetIsLeftOut() throws {
        // As any blank value is: a Shortcut's empty variable still starts.
        #expect(try start("?preset=%20%20").preset == nil)
    }
}
