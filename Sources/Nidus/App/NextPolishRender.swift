import AppKit
import SwiftUI

extension RenderSurfaces {
    /// Focused off-screen checks, with throwaway preferences and no blockers.
    static func renderNextPolish(model: NidusModel, settings: SettingsWindowController, in directory: URL) async {
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
