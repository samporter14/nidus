#if DEBUG
//
//  FocusWorkspaceRender.swift
//  Nidus
//
//  What `--render-surfaces` draws for saved workspaces: a setup's page with a
//  workspace (collapsed, as it first appears, and with every line open), and
//  the card for a start where something could not be opened or a page is
//  blocked. The files are made in a throwaway folder and one is deleted again
//  so it is missing; nothing is opened, and no session is ever started (the
//  cards are drawn from a made-up report, and a render's opener does nothing
//  anyway).
//

import AppKit
import SwiftUI

extension NidusModel {
    /// Demo only: "Grant writing", with two apps, a document, a folder, a
    /// document that has gone missing, two web pages (one of them blocked by
    /// Video) and a start Shortcut. Only ever in the demo's own settings.
    func seedSampleWorkspace(in folder: URL) -> FocusSetup? {
        guard Demo.isActive else { return nil }
        seedSampleCategory()
        seedSampleWorkspaceProjects()
        let manager = FileManager.default
        let references = folder.appendingPathComponent("References", isDirectory: true)
        try? manager.createDirectory(at: references, withIntermediateDirectories: true)
        let aims = folder.appendingPathComponent("Specific Aims.docx")
        let budget = folder.appendingPathComponent("Budget.xlsx")
        manager.createFile(atPath: aims.path, contents: Data())
        manager.createFile(atPath: budget.path, contents: Data())
        let resources: [WorkspaceResource] = [
            .file(at: aims), .file(at: references), .file(at: budget),
            (try? WorkspaceResource.webPage(from: "grants.nih.gov/grants/guide").get()),
            (try? WorkspaceResource.webPage(from: "youtube.com/watch?v=9bZkp7q19f0").get()),
        ].compactMap { $0 }
        // Gone again: a bookmark to it leads nowhere.
        try? manager.removeItem(at: budget)
        return FocusSetup(name: "Grant writing", symbol: "pencil", minutes: 90, categoryIDs: ["social", "video"],
                          goal: "Revise Specific Aims",
                          launchApps: [BlockedApp(bundleID: "com.microsoft.Word", name: "Word"),
                                       BlockedApp(bundleID: "org.zotero.zotero", name: "Zotero")],
                          startShortcut: "Nidus \u{00B7} Work on", resources: resources,
                          project: .project(Self.sampleProject), breakMinutes: 10,
                          breakRules: BreakRules(apps: [], websites: ["x.com", "reddit.com"], reminder: "Stretch, water"))
    }
}

/// What a render says opens a file: a PDF in Preview, a folder in Finder.
private struct SampleAppFinder: DefaultAppFinding {
    func appToOpen(_ url: URL) -> BlockedApp? {
        if url.hasDirectoryPath { return BlockedApp(bundleID: "com.apple.finder", name: "Finder") }
        return url.pathExtension == "pdf" ? BlockedApp(bundleID: "com.apple.Preview", name: "Preview") : nil
    }
}

extension NidusModel {
    /// Demo only: "Deep reading", an allow list of Xcode's category with a
    /// PDF, which opens in Preview, an app that list does not allow.
    func seedSampleReadingSetup(in folder: URL) -> FocusSetup? {
        guard Demo.isActive else { return nil }
        seedSampleCategory()
        let pdf = folder.appendingPathComponent("Aims Reviewer Notes.pdf")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: pdf.path, contents: Data())
        return FocusSetup(name: "Deep reading", symbol: "book", minutes: 60, categoryIDs: ["xcode"], mode: .allow,
                          resources: [.file(at: pdf)])
    }
}

extension NidusModel {
    /// Demo only: the two projects a setup can count toward. Not the
    /// projects render's, which also writes sessions into the history.
    func seedSampleWorkspaceProjects() {
        guard Demo.isActive else { return }
        projects = [FocusProject(id: Self.sampleProject, name: "R01 renewal"), FocusProject(name: "Lab notebook")]
        selectedProjectID = nil
    }
}

extension RenderSurfaces {
    static func renderWorkspaces(model: NidusModel, settings: SettingsWindowController, host: NidusHost,
                                 in directory: URL) async {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("nidus-render-workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.runHarnessScenario("setups")
        guard let sample = model.seedSampleWorkspace(in: folder) else { return }
        let others = model.setups
        // Every render run shares one demo settings domain; put the sample
        // back before each shot (see renderSetups).
        func stage() {
            model.seedSampleCategory()
            model.seedSampleWorkspaceProjects()
            model.setups = others + [sample]
        }
        let page = NidusModel.setupPagePrefix + sample.id.uuidString

        stage()
        await shootSettings(model, settings, page: page, title: sample.displayName,
                            name: "settings-setup-workspace", height: 1500, in: directory)
        stage()
        await shoot(FocusSetupPage(model: model, setupID: sample.id, opened: [.apps, .documents, .pages, .shortcuts, .exceptions, .project, .breakLength, .breakRules])
                        .background(Color(nsColor: .windowBackgroundColor)),
                    width: 640, height: 3100, name: "settings-setup-workspace-open", in: directory)
        stage()
        await shootSettings(model, settings, page: NidusModel.setupsPageID, title: "Setups",
                            name: "settings-setups-workspace", height: 520, in: directory)

        // The cards, as a start would say them. The plan is what the session
        // committed to; the report is what opening it came to.
        var plan = SessionPlan(goal: sample.goal ?? "", duration: 90 * 60, mode: .block,
                               categories: model.categories.filter { sample.categoryIDs.contains($0.id) },
                               reopensQuitApps: false)
        plan.setupID = sample.id
        plan.resources = sample.resources
        let missing = WorkspaceReport(total: 5, opened: 4, problems: [
            .init(resourceID: sample.resources[2].id, name: "Budget.xlsx", kind: .document, reason: .notFound),
        ])
        let clean = WorkspaceReport(total: 5, opened: 5)
        let conflicts = plan.workspaceConflicts(categories: model.categories)
        var twoPages = plan
        twoPages.resources.append(contentsOf: [try? WorkspaceResource.webPage(from: "youtube.com/watch?v=abc123").get(),
                                               try? WorkspaceResource.webPage(from: "reddit.com/r/grants").get()].compactMap { $0 })
        let several = twoPages.workspaceConflicts(categories: model.categories)
        let cards: [(String, WorkspaceReport, [WorkspaceConflict], SessionPlan)] = [
            ("workspace-missing", missing, [], plan),
            ("workspace-conflict", clean, conflicts, plan),
            ("workspace-both", missing, conflicts, plan),
            ("workspace-several", clean, several, twoPages),
        ]
        for (name, report, found, forPlan) in cards {
            stage()
            model.presentWorkspaceHUD(report, conflicts: found, for: forPlan)
            guard let request = host.hud.lastRequest else { continue }
            await shoot(HUDCardView(content: request.content), width: HUDPresenter.width,
                        name: "card-\(name)", in: directory, padded: true)
        }
        // After "Allow only this page" on the card.
        let allowed = WorkspaceCardState()
        allowed.allowed = true
        let lines = NidusModel.workspaceCardLines(report: clean, conflicts: conflicts)
        await shoot(HUDCardView(content: AnyView(
            WorkspaceNoticeCard(symbol: "nosign",
                                title: NidusModel.workspaceCardTitle(setupName: sample.displayName, report: clean, conflicts: conflicts),
                                lines: lines, state: allowed, openSetup: {}, allow: {}))),
                    width: HUDPresenter.width, name: "card-workspace-allowed", in: directory, padded: true)

        // A document that opens in an app the setup does not allow.
        guard let reading = model.seedSampleReadingSetup(in: folder) else { return }
        func stageReading() {
            model.seedSampleCategory()
            model.setups = others + [reading]
        }
        stageReading()
        await shoot(FocusSetupPage(model: model, setupID: reading.id, opened: [.documents])
                        .environment(\.defaultAppFinder, SampleAppFinder())
                        .background(Color(nsColor: .windowBackgroundColor)),
                    width: 640, height: 1500, name: "settings-setup-workspace-app", in: directory)
        var readingPlan = SessionPlan(goal: "", duration: 60 * 60, mode: .allow,
                                      categories: model.categories.filter { reading.categoryIDs.contains($0.id) },
                                      reopensQuitApps: false)
        readingPlan.setupID = reading.id
        readingPlan.resources = reading.resources
        let appConflicts = readingPlan.workspaceConflicts(
            categories: model.categories,
            openedBy: WorkspaceConflicts.openers(for: reading.resources, launcher: WorkspaceLauncher(), finder: SampleAppFinder()))
        stageReading()
        model.presentWorkspaceHUD(clean, conflicts: appConflicts, for: readingPlan)
        if let request = host.hud.lastRequest {
            await shoot(HUDCardView(content: request.content), width: HUDPresenter.width,
                        name: "card-workspace-app", in: directory, padded: true)
        }
        model.setups = others
    }
}

#endif
