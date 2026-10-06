//
//  FinishCardTests.swift
//  NidusTests
//
//  The finish card asks first and, once answered, says so in a few words.
//

import Foundation
import Testing
@testable import Nidus

@MainActor
struct FinishCardTests {
    @Test func theCardConfirmsEachAnswerInAFewWords() {
        #expect(FinishReply.confirmation(true) == "Marked as finished.")
        #expect(FinishReply.confirmation(false) == "Saved for next time.")
    }

    @Test func theConfirmationStaysAsLongAsACardWithNothingToAsk() {
        #expect(FinishReply.linger == 6)
    }
}
