//
//  PopoverPolishTests.swift
//  NidusTests
//
//  The small polish of the popover, the wrap-up card and the menu bar: which
//  one nudge the idle popover shows, which setups have a number key, the
//  wrap-up card's one-line footer, and the sequence block in the menu bar.
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Nidus

struct IdleNudgeTests {
    @Test func theMostUrgentWaitingNudgeWins() {
        #expect(IdleNudge.top(brickOffer: true, resumeNote: true, inbox: true) == .brick)
        #expect(IdleNudge.top(brickOffer: true, resumeNote: false, inbox: true) == .brick)
        #expect(IdleNudge.top(brickOffer: false, resumeNote: true, inbox: true) == .resume)
        #expect(IdleNudge.top(brickOffer: false, resumeNote: true, inbox: false) == .resume)
        #expect(IdleNudge.top(brickOffer: false, resumeNote: false, inbox: true) == .inbox)
        #expect(IdleNudge.top(brickOffer: false, resumeNote: false, inbox: false) == nil)
    }

    @Test func dealingWithOneBringsUpTheNext() {
        var waiting = (brick: true, resume: true, inbox: true)
        var seen: [IdleNudge?] = []
        seen.append(IdleNudge.top(brickOffer: waiting.brick, resumeNote: waiting.resume, inbox: waiting.inbox))
        waiting.brick = false
        seen.append(IdleNudge.top(brickOffer: waiting.brick, resumeNote: waiting.resume, inbox: waiting.inbox))
        waiting.resume = false
        seen.append(IdleNudge.top(brickOffer: waiting.brick, resumeNote: waiting.resume, inbox: waiting.inbox))
        waiting.inbox = false
        seen.append(IdleNudge.top(brickOffer: waiting.brick, resumeNote: waiting.resume, inbox: waiting.inbox))
        #expect(seen == [.brick, .resume, .inbox, nil])
    }

    @Test func atMostOneOfAnyCombinationIsChosen() {
        for bits in 0..<8 {
            let nudge = IdleNudge.top(brickOffer: bits & 1 != 0, resumeNote: bits & 2 != 0, inbox: bits & 4 != 0)
            #expect((nudge == nil) == (bits == 0))
        }
    }
}

@MainActor
struct SetupShortcutTests {
    private func setups(_ count: Int) -> [FocusSetup] {
        (1...count).map { FocusSetup(name: "S\($0)", minutes: 25, categoryIDs: ["social"]) }
    }

    @Test func theFirstFourGetOneToFour() {
        let all = setups(6)
        let numbers = all.map { FocusSetupsBar.shortcutNumber(for: $0, in: all) { _ in nil } }
        #expect(numbers == [1, 2, 3, 4, nil, nil])
    }

    @Test func aSetupThatCannotStartHasNoKey() {
        let all = setups(4)
        let numbers = all.map { setup in
            FocusSetupsBar.shortcutNumber(for: setup, in: all) { $0.id == all[1].id ? .nothingToBlock : nil }
        }
        #expect(numbers == [1, nil, 3, 4], "the others keep their own numbers")
    }

    @Test func noKeyTakesWhatTheGoalFieldNeeds() {
        // ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z are letters; the keys here are the digits 1 to 4.
        #expect(FocusSetupsBar.shortcutCount == 4)
        let all = setups(4)
        for setup in all {
            let number = FocusSetupsBar.shortcutNumber(for: setup, in: all) { _ in nil }
            #expect((1...4).contains(number ?? 0))
        }
    }

    @Test func aSetupOutsideTheListHasNone() {
        let all = setups(2)
        let stranger = FocusSetup(name: "Other", minutes: 25, categoryIDs: ["social"])
        #expect(FocusSetupsBar.shortcutNumber(for: stranger, in: all) { _ in nil } == nil)
    }
}

@MainActor
struct MenuBarStatusTests {
    @Test func aSequenceBlockReadsItsNumberThenTheClock() {
        let status = MenuBarStatus.make(clock: "18:40", onBreak: false, openEnded: false, remaining: 18 * 60 + 40,
                                        block: (number: 2, of: 3))
        #expect(status.text == "2/3 \u{00B7} 18:40")
    }

    @Test func theSpokenTimeIsTheMinutesLeft() {
        let status = MenuBarStatus.make(clock: "18:00", onBreak: false, openEnded: false, remaining: 18 * 60,
                                        block: (2, 3))
        #expect(status.spoken == "Block 2 of 3, 18 minutes left")
    }

    @Test func aSequenceBreakShowsTheBreakClockAsBefore() {
        let status = MenuBarStatus.make(clock: "04:10", onBreak: true, openEnded: false, remaining: 0, block: (2, 3))
        #expect(status.text == "04:10")
        #expect(status.spoken == "04:10 of break left")
    }

    @Test func anOrdinarySessionIsUnchanged() {
        let timed = MenuBarStatus.make(clock: "24:00", onBreak: false, openEnded: false, remaining: 1440, block: nil)
        #expect(timed.text == "24:00")
        #expect(timed.spoken == "24:00 left")
        let open = MenuBarStatus.make(clock: "05:00", onBreak: false, openEnded: true, remaining: 0, block: nil)
        #expect(open.text == "05:00")
        #expect(open.spoken == "05:00 focused")
    }
}

@MainActor
struct WrapUpFooterTests {
    func height<V: View>(_ card: V) -> CGFloat {
        let hosting = NSHostingView(rootView: HUDCardView(content: AnyView(card)))
        hosting.frame = NSRect(x: 0, y: 0, width: HUDPresenter.width, height: 10)
        return ceil(hosting.fittingSize.height)
    }

    private func card(saved: Int, activity: Bool, question: String? = nil, reply: Bool? = nil,
                      openInbox: @escaping () -> Void = {}, openActivity: @escaping () -> Void = {}) -> FocusWrapUpCard {
        FocusWrapUpCard(title: "Session complete", detail: "25 min focused \u{00B7} blocked 4 times",
                        mediumDetail: "25 min focused", shortDetail: "25 min", completed: true,
                        question: question, reply: reply, saved: saved, openInbox: openInbox,
                        openActivity: activity ? openActivity : nil, again: {})
    }

    @Test func bothTogetherTakeLessRoomThanTwoRows() {
        let both = height(card(saved: 3, activity: true))
        let separate = height(card(saved: 3, activity: false)) + height(card(saved: 0, activity: true))
            - height(card(saved: 0, activity: false))
        #expect(both < separate, "both: \(both), separate rows: \(separate)")
        #expect(both > height(card(saved: 0, activity: false)))
    }

    @Test func theFooterCardIsAsTallAnsweredAsAsking() {
        let heights = [nil, true, false].map { reply in
            height(card(saved: 3, activity: true, question: "Write the launch post", reply: reply))
        }
        #expect(Set(heights).count == 1, "heights: \(heights)")
    }

    @Test func theFooterKeepsBothActions() {
        var inbox = 0, activity = 0
        let footer = FocusWrapUpFooter(saved: 2, openInbox: { inbox += 1 }, openActivity: { activity += 1 })
        footer.openInbox()
        footer.openActivity()
        #expect(inbox == 1 && activity == 1)
        #expect(NidusModel.savedForLaterText(2) != nil)
    }
}
