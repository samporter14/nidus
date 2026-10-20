#if DEBUG
//
//  FocusSequencesRender.swift
//  Nidus
//
//  What `--render-surfaces` and `--demo` draw for breaks with rules and for
//  sequences: the editor, the popover in the middle of a run and on its
//  breaks, the break card with its rules and reminder, and Settings' break
//  rules. The samples go into the demo's own settings and folder, and are
//  never started for real: a demo's controller blocks nothing
//  (`FocusController.blocksNothing`).
//

import AppKit
import SwiftUI

extension NidusModel {
    /// Social and Slack, with a note: what the sample breaks keep blocked.
    static var sampleBreakRules: BreakRules {
        let presets = FocusCategory.presets
        let social = presets.first { $0.id == "social" }!
        return BreakRules(reminder: "Stretch, water, look out a window")
            .setting(social, on: true, in: presets)
            .adding(apps: ["com.tinyspeck.slackmacgap"])
    }

    /// Demo only: three sample sequences, with the setup and project they use.
    /// Their ids are fixed, so a page can be named before it is seeded. An
    /// existing sample setup is kept, so the sequences keep pointing at it.
    func seedSampleSequences() {
        guard Demo.isActive else { return }
        if !setups.contains(where: { $0.name == "Writing" }) || !setups.contains(where: { $0.name == "Deep work" }) {
            seedSampleSetups()
        }
        let project = FocusProject(name: "R01 renewal")
        if !projects.contains(where: { $0.name == project.name }) { projects.append(project) }
        let writing = setups.first { $0.name == "Writing" }
        let deep = setups.first { $0.name == "Deep work" }
        sequences = [
            FocusSequence(id: Self.sampleSequenceIDs[0], name: "Grant morning", steps: [
                .work(minutes: 40, goal: "Writing", setupID: writing?.id, projectID: projects.first?.id),
                .rest(minutes: 10, rules: .own(Self.sampleBreakRules)),
                .work(minutes: 25, goal: "Figures", setupID: deep?.id),
            ]),
            FocusSequence(id: Self.sampleSequenceIDs[1], name: "Read, then write", steps: [
                .work(minutes: 30, goal: "Read the new papers"),
                .work(minutes: 45, goal: "Draft the methods"),
            ]),
            FocusSequence(id: Self.sampleSequenceIDs[2], name: "Admin hour", steps: [
                .work(minutes: 25, goal: "Email"),
                .rest(minutes: 5),
                .work(minutes: 25, goal: "Expenses"),
            ]),
        ]
    }

    static let sampleSequenceIDs = [UUID(uuidString: "5E0C1A00-0000-4000-8000-000000000001")!,
                                    UUID(uuidString: "5E0C1A00-0000-4000-8000-000000000002")!,
                                    UUID(uuidString: "5E0C1A00-0000-4000-8000-000000000003")!]

    /// Demo only: a run on screen, as a relaunch would find it, so the popover
    /// and cards can be drawn partway through.
    func stageSequenceRun(onBreak: Bool, direct: Bool = false) {
        guard Demo.isActive, let controller, let host else { return }
        controller.end()
        func plan(_ goal: String, _ minutes: Double) -> SessionPlan {
            var plan = SessionPlan(goal: goal, duration: minutes * 60, mode: .block, apps: [], websites: [])
            plan.breakRules = Self.sampleBreakRules
            return plan
        }
        let steps: [SequenceStep] = direct
            ? [.work(plan("Writing", 40)), .work(plan("Figures", 25)), .work(plan("Email", 15))]
            : [.work(plan("Writing", 40)), .rest(length: 10 * 60, rules: Self.sampleBreakRules), .work(plan("Figures", 25))]
        var run = SequenceRun(name: "Grant morning", steps: steps, startedAt: Date().addingTimeInterval(-25 * 60))
        for index in run.steps.indices {
            if case .work(var p) = run.steps[index] {
                p.sequenceStep = run.ref(at: index)
                run.steps[index] = .work(p)
            }
        }
        let now = Date()
        var record = SessionRecord(sequence: run)
        if onBreak {
            run.index = 1
            guard case .work(let next)? = run.steps.last else { return }
            record = SessionRecord(lastPlan: next,
                                   pendingBreak: BreakState(plan: next, endsAt: now.addingTimeInterval(7 * 60 + 30),
                                                            length: 10 * 60, rules: Self.sampleBreakRules),
                                   sequence: run)
        } else {
            guard case .work(let first)? = run.steps.first else { return }
            record = SessionRecord(session: SessionState(plan: first, startedAt: now.addingTimeInterval(-18 * 60),
                                                         phase: .running(deadline: now.addingTimeInterval(22 * 60)),
                                                         budget: 40 * 60),
                                   lastPlan: first, sequence: run)
        }
        FileSessionStore(url: host.environment.containerDirectory.appendingPathComponent("session.json")).save(record)
        controller.engine.restore()
        objectWillChange.send()
    }

    /// The scenarios `--demo` and the renders use for this feature.
    func runSequenceScenario(_ scenario: String) {
        guard let controller else { return }
        switch scenario {
        case "sequences":
            controller.end()
            seedSampleSequences()
        case "sequence-block":
            seedSampleSequences()
            stageSequenceRun(onBreak: false)
        case "sequence-direct":
            seedSampleSequences()
            stageSequenceRun(onBreak: false, direct: true)
        case "sequence-break":
            seedSampleSequences()
            stageSequenceRun(onBreak: true)
        case "break-rules":
            // An ordinary repeating break that keeps Social and Slack blocked.
            controller.end()
            var next = SessionPlan(goal: "Update Specific Aims", duration: 25 * 60, mode: .block, apps: [], websites: [])
            next.breakRules = Self.sampleBreakRules
            controller.engine.startBreak(plan: next, length: 5 * 60)
        default:
            break
        }
        objectWillChange.send()
    }
}

extension RenderSurfaces {
    /// The sequence editor, the Setups tab with sequences, the popover in the
    /// middle of a run and on a break, the break cards, and Settings' default
    /// break rules. Each shot puts back what it shows first (see
    /// `renderSetups`), and the demo's settings are put back at the end.
    static func renderSequences(model: NidusModel, settings: SettingsWindowController, host: NidusHost, in directory: URL) async {
        model.runHarnessScenario("sequences")
        guard let first = model.sequences.first else { return }
        let popover = NidusPopover(model: model)

        // The Setups tab with its sequences, and one sequence's editor: the
        // first (a break with its own rules), a plain two-block one, and one
        // that cannot start.
        let broken = FocusSequence(name: "Half done", steps: [.rest(minutes: 10), .work(minutes: 0, goal: "Figures", setupID: UUID())])
        let pages: [(String, String, String, CGFloat, Bool)] = [
            (SettingsTab.setups.pageID, "Setups", "settings-setups-sequences", 900, false),
            (NidusModel.sequencePagePrefix + first.id.uuidString, first.displayName, "settings-sequence", 1900, false),
            (NidusModel.sequencePagePrefix + NidusModel.sampleSequenceIDs[1].uuidString, "Read, then write", "settings-sequence-plain", 900, false),
            (NidusModel.sequencePagePrefix + broken.id.uuidString, broken.displayName, "settings-sequence-problems", 1100, true),
        ]
        for (page, title, name, height, withBroken) in pages {
            model.seedSampleSequences()
            if withBroken { model.sequences.append(broken) }
            await shootSettings(model, settings, page: page, title: title, name: name, height: height, in: directory)
        }
        model.seedSampleSequences()
        await shootWindow(settings, page: NidusModel.sequencePagePrefix + first.id.uuidString, title: first.displayName,
                          name: "settings-window-sequence", in: directory)
        settings.window?.orderOut(nil)

        // The popover's bar, with a sequence beside the plus.
        model.runHarnessScenario("sequences")
        await shoot(popover, width: 440, name: "popover-idle-sequences", in: directory)

        // Partway through a run: a block with a break next, a block straight
        // into a block, and the break with its rules and reminder.
        for (scenario, name) in [("sequence-block", "popover-sequence-block"), ("sequence-direct", "popover-sequence-direct"),
                                 ("sequence-break", "popover-sequence-break"), ("break-rules", "popover-break-rules")] {
            model.runHarnessScenario(scenario)
            await shoot(popover, width: 440, name: name, in: directory)
        }

        // The break card as it begins, with its rules and reminder, and the
        // blocked card on a break.
        model.runHarnessScenario("wrapup-break-rules")
        if let request = host.hud.lastRequest {
            await shoot(HUDCardView(content: request.content), width: HUDPresenter.width,
                        name: "card-wrapup-break-rules", in: directory, padded: true)
        }
        model.runHarnessScenario("break-rules")
        model.presentBlockedHUD(for: .website(domain: "x.com"))
        if let request = host.hud.lastRequest {
            await shoot(HUDCardView(content: request.content), width: HUDPresenter.width,
                        name: "card-blocked-break", in: directory, padded: true)
        }

        // Settings' break rules, once breaks are on.
        model.runHarnessScenario("idle")
        model.breakMinutes = 5
        model.defaultBreakRules = NidusModel.sampleBreakRules
        await shootSettings(model, settings, tab: .general, name: "settings-general-break-rules", height: 1700, in: directory)
        model.defaultBreakRules = nil
        model.breakMinutes = 0
        model.runHarnessScenario("idle")
        model.sequences = []
    }
}

#endif
