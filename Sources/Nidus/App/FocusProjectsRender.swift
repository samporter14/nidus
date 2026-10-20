#if DEBUG
//
//  FocusProjectsRender.swift
//  Nidus
//
//  What `--render-surfaces` draws for projects and resume notes: the popover
//  with the project picker and a note to pick up, the finish card with the
//  next-step field, the Projects list and a project's page. The samples go in
//  the demo's own settings and throwaway folder, and nothing here starts a
//  session except the one "running" scenario that shows the busy state, which
//  blocks nothing.
//

import AppKit
import SwiftUI

extension NidusModel {
    private static let sampleProjectID = UUID(uuidString: "5B0F6C0E-1D2A-4F55-9B7A-3C1E0A5D7001")!
    private static let sampleNotebookID = UUID(uuidString: "5B0F6C0E-1D2A-4F55-9B7A-3C1E0A5D7002")!
    private static let sampleArchivedID = UUID(uuidString: "5B0F6C0E-1D2A-4F55-9B7A-3C1E0A5D7003")!
    private static let sampleDeletedID = UUID(uuidString: "5B0F6C0E-1D2A-4F55-9B7A-3C1E0A5D7004")!

    /// The id of the first sample project, for the pages the render opens.
    static var sampleProject: UUID { sampleProjectID }
    static var sampleEmptyProject: UUID { sampleArchivedID }

    /// Demo only (`projects`, `projects-quiet`): three projects (one
    /// archived), the sessions that were counted toward them and toward one
    /// since deleted, and, unless `notes` is false, three resume notes.
    func seedSampleProjects(notes withNotes: Bool = true) {
        guard Demo.isActive else { return }
        let now = Date()
        projects = [
            FocusProject(id: Self.sampleProjectID, name: "R01 renewal", createdAt: now.addingTimeInterval(-86400 * 40)),
            FocusProject(id: Self.sampleNotebookID, name: "Lab notebook", createdAt: now.addingTimeInterval(-86400 * 30)),
            FocusProject(id: Self.sampleArchivedID, name: "Teaching", isArchived: true, createdAt: now.addingTimeInterval(-86400 * 90)),
        ]
        selectedProjectID = withNotes ? Self.sampleProjectID : nil

        if let history = controller?.history {
            history.clear()
            func entry(_ daysAgo: Double, minutes: Double, goal: String, finished: Bool?, completed: Bool = true,
                       project: (UUID, String)?) -> SessionEntry {
                let start = now.addingTimeInterval(-86400 * daysAgo)
                return SessionEntry(start: start, end: start.addingTimeInterval(minutes * 60 + 90), focused: minutes * 60,
                                    planned: 45 * 60, outcome: completed ? .completed : .endedEarly, goal: goal,
                                    finished: finished, projectID: project?.0, projectName: project?.1)
            }
            let aims = (Self.sampleProjectID, "R01 renewal"), book = (Self.sampleNotebookID, "Lab notebook")
            for sample in [
                entry(4.2, minutes: 45, goal: "Update Specific Aims", finished: false, project: aims),
                entry(3.1, minutes: 25, goal: "Update Specific Aims", finished: false, project: aims),
                entry(3.0, minutes: 50, goal: "Budget justification", finished: false, completed: false, project: aims),
                entry(1.2, minutes: 45, goal: "Power analysis for Aim 2", finished: true, project: aims),
                entry(0.4, minutes: 30, goal: "", finished: nil, project: aims),
                entry(2.0, minutes: 25, goal: "Label the freezer boxes", finished: true, project: book),
                entry(6.0, minutes: 40, goal: "Pilot write-up", finished: true, project: (Self.sampleDeletedID, "Old pilot")),
            ] { history.append(sample) }
        }

        resumeNotes?.clear()
        if withNotes, let store = resumeNotes {
            store.add(ResumeNote(text: "Add the power analysis to Aim 2",
                                 resource: WorkspaceResource(kind: .document, displayName: "Aims draft v3.docx", path: "/nowhere/Aims draft v3.docx"),
                                 goal: "Update Specific Aims", projectID: Self.sampleProjectID, projectName: "R01 renewal",
                                 createdAt: now.addingTimeInterval(-3600)))
            store.add(ResumeNote(text: "Rerun Figure 3 with the new cohort", goal: "Label the freezer boxes",
                                 projectID: Self.sampleNotebookID, projectName: "Lab notebook",
                                 createdAt: now.addingTimeInterval(-86400)))
            store.add(ResumeNote(text: "Email the core about the reagent order", goal: "Clear the inbox",
                                 createdAt: now.addingTimeInterval(-86400 * 2)))
        }
        objectWillChange.send()
    }

    /// Demo only (`finish-next`, `finish-next-empty`, `finish-next-notyet`,
    /// `finish-next-off`): the finish card after the question is answered,
    /// with the next-step field empty or filled in, and with sessions not
    /// being recorded (no question, a note only).
    func presentSampleNextStep(_ scenario: String) {
        guard Demo.isActive, let controller, var final = controller.engine.session else { return }
        final.focusedTime = 25 * 60
        final.blocks = ["youtube.com": 3, "com.tinyspeck.slackmacgap": 1]
        resumeNotes?.clear()
        let historyOff = scenario == "finish-next-off"
        let wasRecording = recordsHistory
        recordsHistory = !historyOff
        let step = beginNextStep(for: final, entry: nil)
        recordsHistory = wasRecording
        setDemoQuestion(goal: historyOff ? nil : final.plan.goal)
        presentWrapUpHUD(for: final, completed: true, askAbout: pendingFinish?.goal, nextStep: step)
        if !historyOff { answerFinished(scenario != "finish-next-notyet") }
        if scenario != "finish-next-empty" {
            step?.setText("Rerun Figure 3 with the new cohort")
            step?.setResource(ResumeResources.webPage(from: "example.org/figure-3"))
        }
    }
}

extension RenderSurfaces {
    /// The pictures for projects and notes. Every shot puts back what it
    /// shows first: runs of `--render-surfaces` share one demo settings
    /// domain (see FocusSetupsRender).
    static func renderProjects(model: NidusModel, settings: SettingsWindowController, host: NidusHost, in directory: URL) async {
        let popover = NidusPopover(model: model)

        // The popover: a picker and a note to pick up; the picker alone; a
        // project chosen while a long goal is typed.
        model.runHarnessScenario("projects")
        model.goalDraft = ""
        await shoot(popover, width: 440, name: "popover-projects", in: directory)
        model.runHarnessScenario("projects-quiet")
        await shoot(popover, width: 440, name: "popover-projects-picker", in: directory)
        model.runHarnessScenario("projects")
        model.goalDraft = "Finish the methods section and rerun every figure for the revision"
        await shoot(popover, width: 440, name: "popover-projects-long", in: directory)
        model.goalDraft = ""

        // The finish card with its next-step field.
        for scenario in ["finish-next-empty", "finish-next", "finish-next-notyet", "finish-next-off"] {
            model.runHarnessScenario("projects-quiet")
            model.runHarnessScenario(scenario)
            guard let request = host.hud.lastRequest else { continue }
            await shoot(HUDCardView(content: request.content), width: HUDPresenter.width,
                        name: "card-\(scenario)", in: directory, padded: true)
        }

        // Settings: the Projects list on the Stats page, and a project's
        // page: with notes and unfinished goals, empty, and mid-session.
        model.runHarnessScenario("projects")
        await shootSettings(model, settings, page: "stats", title: "Stats", name: "settings-stats-projects", height: 1500, in: directory)
        model.runHarnessScenario("projects")
        let page = NidusModel.projectPagePrefix + NidusModel.sampleProject.uuidString
        await shootSettings(model, settings, page: page, title: "R01 renewal", name: "settings-project", height: 1300, in: directory)
        model.runHarnessScenario("projects")
        await shootSettings(model, settings, page: NidusModel.projectPagePrefix + NidusModel.sampleEmptyProject.uuidString,
                            title: "Teaching", name: "settings-project-archived", height: 760, in: directory)
        model.runHarnessScenario("projects")
        model.runHarnessScenario("running")
        await shootSettings(model, settings, page: page, title: "R01 renewal", name: "settings-project-busy", height: 1300, in: directory)

        // The list before there is a project.
        model.runHarnessScenario("idle")
        model.projects = []
        model.resumeNotes?.clear()
        model.controller?.clearHistory()
        await shootSettings(model, settings, page: "stats", title: "Stats", name: "settings-stats-no-projects", height: 700, in: directory)
        await shoot(popover, width: 440, name: "popover-no-projects", in: directory)

        // Leave nothing in the demo's folder.
        model.resumeNotes?.clear()
        model.controller?.clearHistory()
    }
}

#endif
