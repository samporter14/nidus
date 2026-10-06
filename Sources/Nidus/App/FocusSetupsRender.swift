//
//  FocusSetupsRender.swift
//  Nidus
//
//  What `--render-surfaces` draws for setups: the Settings list, one setup's
//  page, and the popover's bar with none, a few, and more than fit. The
//  sample setups go into the demo's own settings, which are emptied at each
//  launch, and none is ever started.
//

import AppKit
import SwiftUI

extension NidusModel {
    /// Demo only (the `setups` scenario): three sample setups, and the
    /// category the first allows. Only ever in the demo's own settings.
    func seedSampleSetups() {
        guard Demo.isActive else { return }
        seedSampleCategory()
        setups = [
            FocusSetup(name: "Deep work", symbol: "brain.head.profile", minutes: 90,
                       categoryIDs: ["xcode"], mode: .allow, strict: true),
            FocusSetup(name: "Writing", symbol: "pencil", minutes: 45,
                       categoryIDs: ["social", "video", "messaging"], goal: "Draft the next section"),
            FocusSetup(name: "Reading", symbol: "book", minutes: 0, categoryIDs: ["social", "news"]),
        ]
    }

    /// The category "Deep work" allows. Demo only.
    func seedSampleCategory() {
        guard Demo.isActive else { return }
        let xcode = FocusCategory(id: "xcode", name: "Xcode", symbol: "hammer",
                                  apps: [BlockedApp(bundleID: "com.apple.dt.Xcode", name: "Xcode")], websites: [])
        if !categories.contains(where: { $0.id == xcode.id }) { categories.append(xcode) }
    }
}

extension RenderSurfaces {
    /// Every `--render-surfaces` and `--demo` run shares one demo settings
    /// domain and empties it at launch, so a run begun elsewhere meanwhile
    /// (another worktree's, say) wipes what this one seeded. Each shot
    /// therefore puts back what it shows, first.
    static func renderSetups(model: NidusModel, settings: SettingsWindowController, in directory: URL) async {
        model.runHarnessScenario("setups")
        let samples = model.setups
        guard let first = samples.first else { return }

        func stage(_ setups: [FocusSetup]) {
            model.seedSampleCategory()
            model.setups = setups
        }

        // One whose only category has been deleted, so it can't start.
        let broken = FocusSetup(name: "Old setup", symbol: "moon", minutes: 25, categoryIDs: ["deleted"])
        let pages: [(String?, String, String, CGFloat, [FocusSetup])] = [
            (nil, "", "settings-main-with-setups", 560, samples),
            (NidusModel.setupsPageID, "Setups", "settings-setups", 420, samples),
            (NidusModel.setupPagePrefix + first.id.uuidString, first.displayName, "settings-setup", 1000, samples),
            (NidusModel.setupPagePrefix + broken.id.uuidString, broken.displayName, "settings-setup-broken", 1000, samples + [broken]),
            // The list before there is a setup.
            (NidusModel.setupsPageID, "Setups", "settings-setups-empty", 260, []),
        ]
        for (page, title, name, height, setups) in pages {
            stage(setups)
            settings.router.reset(to: page, title: title)
            await shoot(SettingsRoot(model: model, router: settings.router), width: 640, height: height,
                        name: name, in: directory)
        }

        // The bar at the popover's content width, 440 less 20 each side.
        let many = samples + [
            FocusSetup(name: "Admin", symbol: "envelope", minutes: 25, categoryIDs: ["social"]),
            FocusSetup(name: "Lab notes", symbol: "flask", minutes: 60, categoryIDs: ["news"]),
        ]
        let longNames = samples.map { setup -> FocusSetup in
            var long = setup
            long.name += " and a longer name"
            return long
        } + [many[3]]
        for (label, setups) in [("three", samples), ("five", many), ("long", longNames),
                                ("broken", samples + [broken]), ("empty", [])] as [(String, [FocusSetup])] {
            stage(setups)
            // Alone, which draws nothing, so no file, when there are none.
            if FocusSetupsBar.isVisible(model: model) {
                await shoot(FocusSetupsBar(model: model), width: 400, name: "setups-bar-\(label)",
                            in: directory, padded: true)
                stage(setups)
            }
            await shoot(InPopover(model: model), width: 400, name: "setups-bar-\(label)-in-popover",
                        in: directory, padded: true)
        }
        stage(samples)
    }
}

/// The bar where the popover puts it, over stand-ins for the length and
/// categories row, so its spacing can be judged.
private struct InPopover: View {
    @ObservedObject var model: NidusModel

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.md) {
            Text("What are you working on?")
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            FocusSetupsBar(model: model)
            HStack(spacing: DroppySpacing.sm) {
                Label("25 min", systemImage: "timer").frame(height: 28)
                Label("Social, Video", systemImage: "nosign").frame(height: 28)
                Spacer()
                Button("Start") {}.buttonStyle(.borderedProminent).tint(FocusPalette.clay).controlSize(.large)
            }
        }
    }
}
