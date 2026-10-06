//
//  SnoozeWaitTests.swift
//  NidusTests
//
//  A pause before a snooze: the countdown, what a request to snooze does
//  with the pause set, and when the card has nothing left to offer.
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Nidus

private let began = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func wait(_ seconds: Int = 10, key: String = "youtube.com", name: String? = nil) -> SnoozeWait {
    SnoozeWait(key: key, name: name ?? key, startedAt: began, seconds: seconds)
}

struct SnoozeCountdownTests {
    @Test func itReadsWholeSecondsRoundedUp() {
        let w = wait(10)
        #expect(w.secondsLeft(at: began) == 10, "the first second reads 10, not 9")
        #expect(w.secondsLeft(at: began.addingTimeInterval(0.4)) == 10)
        #expect(w.secondsLeft(at: began.addingTimeInterval(1)) == 9)
        #expect(w.secondsLeft(at: began.addingTimeInterval(9.5)) == 1, "never 0 sec before it is over")
        #expect(w.secondsLeft(at: began.addingTimeInterval(10)) == 0)
        #expect(w.secondsLeft(at: began.addingTimeInterval(500)) == 0, "and stays there")
    }

    @Test func itIsReadyOnTheDotAndNotBefore() {
        let w = wait(10)
        #expect(!w.isReady(at: began))
        #expect(!w.isReady(at: began.addingTimeInterval(9.9)))
        #expect(w.isReady(at: began.addingTimeInterval(10)))
        #expect(w.isReady(at: began.addingTimeInterval(11)))
    }

    @Test func aTickAHairOffStillReadsAsItsOwnSecond() {
        let w = wait(30)
        // The timeline's tick for second 4, a hair early or a hair late.
        #expect(w.secondsLeft(at: began.addingTimeInterval(4 - 0.001)) == 26)
        #expect(w.secondsLeft(at: began.addingTimeInterval(4 + 0.001)) == 26)
        // A clock that stepped back a little never reads more than the wait.
        #expect(w.secondsLeft(at: began.addingTimeInterval(-3)) == 30)
    }

    @Test func theRingFillsAsTheWaitGoes() {
        let w = wait(10)
        #expect(w.progress(at: began) == 0)
        #expect(w.progress(at: began.addingTimeInterval(5)) == 0.5)
        #expect(w.progress(at: began.addingTimeInterval(10)) == 1)
        #expect(w.progress(at: began.addingTimeInterval(99)) == 1)
    }

    @Test func theCardStaysForTheWaitAndALittleAfter() {
        let w = wait(10)
        #expect(w.cardDuration == 10 + SnoozeWait.readyWindow)
        #expect(!w.isLapsed(at: began.addingTimeInterval(15)))
        #expect(w.isLapsed(at: began.addingTimeInterval(w.cardDuration + 1)))
    }
}

struct SnoozeWaitWordsTests {
    @Test func theCardSaysWhatItIsAboutAndHowLongIsLeft() {
        let w = wait(10, key: "com.tinyspeck.slackmacgap", name: "Slack")
        #expect(w.title == "Snooze Slack?")
        #expect(w.detail(at: began) == "Take a breath first. You can snooze in 10 sec.")
        #expect(w.detail(at: began.addingTimeInterval(6)) == "Take a breath first. You can snooze in 4 sec.")
    }

    @Test func whenItIsOverItNoLongerCountsDown() {
        let w = wait(10)
        #expect(w.detail(at: began.addingTimeInterval(10)) == "Take a breath first. You can snooze now.")
    }

    @Test func voiceOverGetsFullWords() {
        let w = wait(30)
        #expect(w.spokenSummary == "Snooze youtube.com? Take a breath first. You can snooze in 30 seconds.")
        #expect(w.buttonLabel(at: began) == "Snooze youtube.com, available in 30 seconds")
        #expect(w.buttonLabel(at: began.addingTimeInterval(29)) == "Snooze youtube.com, available in 1 second")
        #expect(w.buttonLabel(at: began.addingTimeInterval(30)) == "Snooze youtube.com")
    }

    @Test func settingsOffersThreeChoicesInPlainWords() {
        #expect(SnoozeWait.choices == [0, 10, 30])
        #expect(SnoozeWait.choices.map(SnoozeWait.choiceLabel) == ["Snooze right away", "Wait 10 seconds", "Wait 30 seconds"])
    }

    @Test func aStrayChoiceMeansNoWait() {
        #expect(SnoozeWait.normalized(10) == 10)
        #expect(SnoozeWait.normalized(30) == 30)
        for stray in [-5, 7, 45, 600] { #expect(SnoozeWait.normalized(stray) == 0) }
    }
}

@MainActor
struct SnoozeRequestTests {
    static let key = "youtube.com"

    func decide(_ h: Harness, wait seconds: Int, existing: SnoozeWait? = nil, key: String = key, after: TimeInterval = 0) -> SnoozeWait.Decision {
        SnoozeWait.decide(key: key, name: key, waitSeconds: seconds, session: h.engine.session,
                          existing: existing, now: h.clock.now.addingTimeInterval(after))
    }

    @Test func withNoWaitSetItSnoozesAtOnceAsItAlwaysDid() {
        let h = Harness()
        h.engine.start(plan())
        #expect(decide(h, wait: 0) == .snoozeNow)
        #expect(decide(h, wait: 7) == .snoozeNow, "a stray setting is no wait")
    }

    @Test func withAWaitSetItStartsOneNow() {
        let h = Harness()
        h.engine.start(plan())
        let started = h.clock.now
        #expect(decide(h, wait: 10) == .wait(SnoozeWait(key: Self.key, name: Self.key, startedAt: started, seconds: 10)))
    }

    @Test func aStrictSessionHasNoSnoozeWithOrWithoutAWait() {
        let h = Harness()
        h.engine.start(strictPlan())
        #expect(decide(h, wait: 10) == .refuse)
        #expect(decide(h, wait: 0) == .refuse)
    }

    @Test func aPausedOrIdleSessionHasNothingToSnooze() {
        let h = Harness()
        #expect(decide(h, wait: 10) == .refuse, "no session")
        h.engine.start(plan())
        h.engine.pause()
        #expect(decide(h, wait: 10) == .refuse, "paused: the engine would ignore the click")
        #expect(decide(h, wait: 0) == .refuse)
        h.engine.resume()
        h.engine.systemWillSleep()
        #expect(decide(h, wait: 10) == .refuse, "asleep")
    }

    @Test func anItemAlreadyLetThroughIsNotWaitedOn() {
        let h = Harness()
        h.engine.start(plan())
        h.engine.snooze(Self.key)
        #expect(decide(h, wait: 10) == .refuse)
        #expect(decide(h, wait: 0) == .snoozeNow, "without a wait a snooze can still be taken again, as before")
    }

    @Test func askingAgainKeepsTheCountdownItHas() throws {
        let h = Harness()
        h.engine.start(plan())
        guard case .wait(let first) = decide(h, wait: 10) else { Issue.record("expected a wait"); return }

        h.clock.advance(4)
        // A second click on the block page's link: the same wait, not a new one.
        #expect(decide(h, wait: 10, existing: first) == .wait(first))
        // Even with the setting changed in between: it cannot be shortened by asking.
        #expect(decide(h, wait: 30, existing: first) == .wait(first))
        // And once it is over, while the card is still up, it is still the one on offer.
        h.clock.advance(8)
        #expect(decide(h, wait: 10, existing: first) == .wait(first))
    }

    @Test func aWaitForAnotherItemOrOneLongGoneStartsAfresh() {
        let h = Harness()
        h.engine.start(plan())
        guard case .wait(let first) = decide(h, wait: 10) else { Issue.record("expected a wait"); return }

        guard case .wait(let other) = decide(h, wait: 10, existing: first, key: "com.tinyspeck.slackmacgap") else {
            Issue.record("expected a wait")
            return
        }
        #expect(other.key == "com.tinyspeck.slackmacgap")

        // The card went away long ago, so this is a new request, not the old one's end.
        h.clock.advance(first.cardDuration + 5)
        guard case .wait(let later) = decide(h, wait: 10, existing: first) else { Issue.record("expected a wait"); return }
        #expect(later.startedAt == h.clock.now)
        #expect(!later.isReady(at: h.clock.now))
    }
}

@MainActor
struct SnoozeWaitLifetimeTests {
    let key = "youtube.com"

    @Test func itStaysWhileTheSessionRunsAndTheItemIsStillBlocked() {
        let h = Harness()
        h.engine.start(plan())
        #expect(SnoozeWait.isStillBlocked(key, in: h.engine.session))
        h.clock.advance(5 * minute)
        h.engine.tick()
        #expect(SnoozeWait.isStillBlocked(key, in: h.engine.session))
    }

    @Test func itGoesWhenTheSessionEnds() {
        let h = Harness()
        h.engine.start(plan())
        h.engine.end()
        #expect(!SnoozeWait.isStillBlocked(key, in: h.engine.session))
    }

    @Test func itGoesWhenTheSessionRunsOut() {
        let h = Harness()
        h.engine.start(plan(25))
        h.clock.advance(25 * minute)
        h.engine.tick()
        #expect(h.engine.session == nil)
        #expect(!SnoozeWait.isStillBlocked(key, in: h.engine.session))
    }

    @Test func itGoesWhenTheSessionIsPausedAndComesNotBackByItself() {
        let h = Harness()
        h.engine.start(plan())
        h.engine.pause()
        #expect(!SnoozeWait.isStillBlocked(key, in: h.engine.session))
    }

    @Test func itGoesWhenTheItemIsLetThroughSomeOtherWay() {
        let h = Harness()
        h.engine.start(plan())
        h.engine.snooze(key)
        #expect(!SnoozeWait.isStillBlocked(key, in: h.engine.session))
        #expect(SnoozeWait.isStillBlocked("com.tinyspeck.slackmacgap", in: h.engine.session), "only that item")
        h.engine.endSnooze(key)
        #expect(SnoozeWait.isStillBlocked(key, in: h.engine.session), "blocked again")
    }

    @Test func itGoesWithNoSession() {
        #expect(!SnoozeWait.isStillBlocked(key, in: nil))
    }
}

/// The cards are measured once, when they come up, and cannot grow after:
/// every state a card passes through has to be as tall as the first.
@MainActor
struct CardHeightTests {
    func height<V: View>(_ card: V) -> CGFloat {
        let hosting = NSHostingView(rootView: HUDCardView(content: AnyView(card)))
        hosting.frame = NSRect(x: 0, y: 0, width: HUDPresenter.width, height: 10)
        return ceil(hosting.fittingSize.height)
    }

    @Test func theWaitCardIsAsTallAtTheStartAsAtTheEnd() {
        let w = wait(30, name: "a-rather-long-site-name-for-a-card.example.com")
        let heights = [0.0, 1, 15, 29, 30, 99].map { elapsed in
            height(FocusSnoozeWaitCard(wait: w, asOf: began.addingTimeInterval(elapsed), snooze: {}, cancel: {}))
        }
        #expect(Set(heights).count == 1, "heights: \(heights)")
        #expect(heights[0] > 0)
    }

    @Test(arguments: ["Again", "Skip break"])
    func theFinishCardIsAsTallAnsweredAsAsking(_ button: String) {
        func card(_ reply: Bool?) -> FocusWrapUpCard {
            FocusWrapUpCard(title: "Session complete", detail: "25 min focused · blocked 4 times",
                            mediumDetail: "25 min focused", shortDetail: "25 min", completed: true,
                            button: button, question: "Write the launch post", reply: reply, again: {})
        }
        let heights = [nil, true, false].map { height(card($0)) }
        #expect(Set(heights).count == 1, "heights: \(heights)")
        #expect(heights[0] > 0)
    }
}
