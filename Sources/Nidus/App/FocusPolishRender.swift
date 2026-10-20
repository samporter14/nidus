#if DEBUG
//
//  FocusPolishRender.swift
//  Nidus
//
//  What `--render-surfaces` draws for the 0.4 polish: the idle popover with
//  a phone request, a resume note and the inbox all waiting (it shows only
//  the first, then the next as each is dealt with), and the wrap-up card's
//  one-line footer. Demo settings and the throwaway folder only; nothing
//  here starts a session.
//

import AppKit
import SwiftUI

extension RenderSurfaces {
    static func renderPolish(model: NidusModel, in directory: URL) async {
        let popover = NidusPopover(model: model)

        // Three nudges waiting: the phone's request alone, then the note
        // once that is dismissed, then the inbox once the note is gone.
        model.runHarnessScenario("projects")
        model.runHarnessScenario("brick-offer")
        model.seedSampleInbox()
        model.goalDraft = ""
        await shoot(popover, width: 440, name: "popover-nudges-brick", in: directory)
        model.dismissBrickOffer()
        await shoot(popover, width: 440, name: "popover-nudges-resume", in: directory)
        model.resumeNotes?.clear()
        await shoot(popover, width: 440, name: "popover-nudges-inbox", in: directory)

        // The wrap-up card with a count and the session's activity: one
        // footer line; with the question above it; and a long count.
        func card(question: String? = nil, saved: Int = 3) -> some View {
            HUDCardView(content: AnyView(FocusWrapUpCard(
                title: "Session complete", detail: "25 min focused \u{00B7} blocked 4 times \u{00B7} day 12 in a row",
                mediumDetail: "25 min focused \u{00B7} day 12 in a row", shortDetail: "25 min \u{00B7} day 12",
                completed: true, question: question, saved: saved, openInbox: {}, openActivity: {}, again: {})))
        }
        await shoot(card(), width: HUDPresenter.width, name: "card-wrapup-footer", in: directory, padded: true)
        await shoot(card(question: "Write the launch post"), width: HUDPresenter.width,
                    name: "card-wrapup-footer-question", in: directory, padded: true)
        await shoot(card(saved: 1), width: HUDPresenter.width, name: "card-wrapup-footer-one", in: directory, padded: true)

        model.runHarnessScenario("idle")
        model.resumeNotes?.clear()
        model.inbox?.clear()
        model.controller?.clearHistory()
    }
}

#endif
