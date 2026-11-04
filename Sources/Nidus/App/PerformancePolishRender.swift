import AppKit
import SwiftUI

extension RenderSurfaces {
    /// The recovered polish work, using only the render's throwaway model.
    /// Each fixture is drawn in both themes by the existing flat renderer.
    static func renderPerformancePolish(model: NidusModel, in directory: URL) async {
        guard Demo.isActive, isActive else { return }
        model.runHarnessScenario("idle")
        model.setupDraft = nil
        model.goalDraft = ""
        model.untilTarget = nil
        model.customLengthDraft = nil
        model.selectedResumeNoteID = nil
        model.resumeNotes?.clear()
        model.projects = []
        model.selectedProjectID = nil
        model.setups = []
        model.categories = FocusCategory.presets
        model.selectedCategoryIDs = ["social", "messaging"]
        model.durationMinutes = 25
        model.mode = .block
        model.strictMode = false
        model.recordsHistory = true
        model.showsBotanicalStamps = true
        model.seedSampleHistory()
        // Seeds append directly to history, outside the controller's version
        // counter, so the previous render's cached aggregates must be dropped.
        model.clearPresentationCaches()
        await shootBrickPreview(NidusPopover(model: model), width: 440,
                                name: "polish-botanical-week", in: directory)

        let setup = FocusSetup(name: "Writing", symbol: "pencil", minutes: 45,
                               categoryIDs: ["social", "messaging"], goal: "Draft the next section")
        model.setups = [setup]
        // Stage the same value draft as Use as starting point, without opening
        // a live menu-bar popover or taking keyboard focus during a render.
        model.setupDraft = SetupComposerDraft(setup: setup, categories: model.categories,
                                              goal: "", project: nil, projects: [])
        model.goalDraft = "Revise the introduction"
        model.composerMinutes = 35
        await shootBrickPreview(NidusPopover(model: model), width: 440,
                                name: "polish-setup-starting-point", in: directory)

        model.setupDraft = nil
        model.goalDraft = ""
        model.setups = []
        let now = Date()
        let earlier = ResumeNote(text: "Check the figure captions", goal: "Revise the figures",
                                 createdAt: now.addingTimeInterval(-86400))
        let latest = ResumeNote(text: "Write the summary paragraph", goal: "Draft the next section",
                                createdAt: now.addingTimeInterval(-3600))
        model.resumeNotes?.add(earlier)
        model.resumeNotes?.add(latest)
        model.selectedResumeNoteID = earlier.id
        await shootBrickPreview(NidusPopover(model: model), width: 440,
                                name: "polish-other-next-steps", in: directory)

        model.resumeNotes?.clear()
        model.selectedResumeNoteID = nil
        model.runHarnessScenario("break")
        await shootBrickPreview(NidusPopover(model: model), width: 440,
                                name: "polish-break-resting-glyph", in: directory)
        model.runHarnessScenario("idle")
    }
}
