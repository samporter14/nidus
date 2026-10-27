import AppKit
import SwiftUI

extension RenderSurfaces {
    /// Focused off-screen checks, with throwaway preferences and no blockers.
    static func renderNextPolish(model: NidusModel, settings: SettingsWindowController, in directory: URL) async {
        model.runHarnessScenario("idle")
        model.resumeNotes?.clear()
        model.breakMinutes = 5
        model.goalDraft = "Write for 45m"
        await shootBrickPreview(NidusPopover(model: model), width: 440, name: "session-preview", in: directory)
        if let preview = model.sessionPreview() {
            await shootBrickPreview(SessionPreviewRow(preview: preview, expanded: true), width: 370,
                                   name: "session-preview-details", in: directory)
        }
        for scenario in ["finish-next-empty", "finish-next", "finish-next-notyet", "finish-next-off"] {
            model.runHarnessScenario("running")
            model.runHarnessScenario(scenario)
            if let request = model.host?.hud.lastRequest {
                await shootBrickPreview(request.content, width: HUDPresenter.width - 32,
                                       name: "session-\(scenario)", in: directory)
            }
        }
        model.runHarnessScenario("running")
        if var final = model.engine?.session {
            final.plan.goal = ""
            final.focusedTime = 25 * 60
            let step = model.beginNextStep(for: final, entry: nil)
            await shootBrickPreview(FocusWrapUpCard(title: "Session complete", detail: "25 min focused",
                mediumDetail: "25 min focused", shortDetail: "25 min focused", completed: true, nextStep: step, again: {}),
                width: HUDPresenter.width - 32, name: "session-unnamed-finish", in: directory)
        }
        model.runHarnessScenario("idle")
        await shoot(NidusSymbolBrowser(selection: .constant("leaf")), width: 350,
                    name: "symbol-picker", in: directory)
        model.categories = FocusCategory.presets.filter { ["social", "messaging", "video", "news", "mail"].contains($0.id) }
        await shoot(FocusBlockingPage(model: model, showsSuggested: true).environment(SettingsRouter()),
                    width: 640, height: 1450, name: "blocking-suggestions", in: directory)
        let custom = FocusCategory(id: "sample-news", name: "News", symbol: "newspaper", apps: [], websites: ["cnn.com", "bbc.com"])
        model.categories.append(custom)
        await shoot(FocusCategoryPage(model: model, categoryID: custom.id).environment(SettingsRouter()),
                    width: 640, height: 750, name: "category-editor", in: directory)
        if let setup = model.setups.first {
            await shootSettings(model, settings, page: NidusModel.setupPagePrefix + setup.id.uuidString,
                                title: setup.displayName, name: "setup-editor", height: 950, in: directory)
        }
        model.goalDraft = ""
        model.startProblem = "Choose a category with apps or websites in Blocking."
        await shoot(NidusPopover(model: model), width: 440, name: "refused-start", in: directory)
        model.startProblem = nil
        if let entry = SettingsJumpIndex.entries.first(where: { $0.id == "plaque" }) {
            model.settingsJump.open(entry)
            await shootWindow(settings, page: "general", name: "jump-to-plaque", in: directory)
        }
        settings.window?.close()
        print("SETTINGS_RELEASED \(settings.window == nil)")
    }
}
