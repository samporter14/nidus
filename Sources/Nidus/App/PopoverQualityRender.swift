#if DEBUG
//
//  PopoverQualityRender.swift
//  Nidus
//
//  What `--render-surfaces` draws for the idle popover's quality-of-life
//  work: the Start button saying a break follows (with its Return hint), a
//  length typed in the goal and the chip that reads it, and the quiet offer
//  to save a plan started by hand. Demo settings and the throwaway folder
//  only; nothing here starts a session.
//

import AppKit
import SwiftUI

extension RenderSurfaces {
    static func renderPopoverQuality(model: NidusModel, in directory: URL) async {
        let popover = NidusPopover(model: model)
        let savedSetups = model.setups
        let savedBreak = model.breakMinutes
        let savedLength = model.durationMinutes
        model.runHarnessScenario("idle")
        model.setups = []
        model.goalDraft = ""

        // No break: the button as it was. Then a 5 minute break.
        model.breakMinutes = 0
        await shoot(popover, width: 440, name: "popover-quality-no-break", in: directory)
        model.breakMinutes = 5
        await shoot(popover, width: 440, name: "popover-quality-break", in: directory)

        // A length typed at the end of the goal.
        model.goalDraft = "Aims for 45m"
        await shoot(popover, width: 440, name: "popover-quality-goal-minutes", in: directory)
        model.goalDraft = "Aims until 3:30pm"
        await shoot(popover, width: 440, name: "popover-quality-goal-until", in: directory)
        model.goalDraft = "Finish the methods section and rerun every figure for the revision for 1h30"
        await shoot(popover, width: 440, name: "popover-quality-goal-long", in: directory)
        model.goalDraft = "Wait for the build"
        await shoot(popover, width: 440, name: "popover-quality-goal-plain", in: directory)
        model.goalDraft = ""

        // The longest the button gets.
        model.durationMinutes = 187
        await shoot(popover, width: 440, name: "popover-quality-break-long", in: directory)
        model.durationMinutes = savedLength

        // The same plan started three times, no setup saved.
        let plan = PlanSignature(minutes: model.durationMinutes, categoryIDs: model.selectedCategories.map(\.id), mode: model.mode)
        for hours in [30.0, 5, 1] { model.notePlanStarted(plan, now: Date().addingTimeInterval(-hours * 3600)) }
        await shoot(popover, width: 440, name: "popover-quality-suggest", in: directory)
        model.dismissSetupSuggestion()
        await shoot(popover, width: 440, name: "popover-quality-suggest-dismissed", in: directory)

        model.clearPlanStarts()
        model.setups = savedSetups
        model.breakMinutes = savedBreak
        model.durationMinutes = savedLength
    }
}

#endif
