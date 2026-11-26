//
//  TargetRenders.swift
//  Nidus
//
//  What `--render-activity-surfaces` and `--render-popover-surfaces` draw for
//  daily category targets (0.7.1). Added to the end of each run, after the
//  existing pictures, so none of them changes: the seeded day carries no
//  targets, and these set theirs from what the day holds, so the render shows
//  one met and one part-way however far into the day it is made.
//

import AppKit
import SwiftUI

extension RenderSurfaces {
    /// Seconds in a group on one day of the seeded record.
    private static func seconds(in group: String, on day: Date, model: NidusModel) -> TimeInterval {
        guard let recorder = model.controller?.activityRecorder,
              let log = recorder.store.load(day: ActivityDayLog.key(for: day, calendar: .current)) else { return 0 }
        return model.activityCategorizer.totals(of: log.stretches).first { $0.id == group }?.seconds ?? 0
    }

    /// A target a day has already reached (a whole minute at or under it) and
    /// one it is about halfway to.
    private static func met(_ done: TimeInterval) -> TimeInterval { max(60, (done / 60).rounded(.down) * 60) }
    private static func partway(_ done: TimeInterval) -> TimeInterval { max(120, (done * 2 / 60).rounded(.up) * 60) }

    /// Activity: the overview with two targets (Work met, AI chat part-way),
    /// a week of daily bars cut to Work with its target line, the month, and
    /// Settings with a category's target.
    static func renderCategoryTargets(model: NidusModel, in directory: URL) async {
        let today = Date()
        let work = seconds(in: ActivityCategorizer.workID, on: today, model: model)
        let chat = seconds(in: "ai-chat", on: today, model: model)
        model.updateWorkGroup { $0.dailyTarget = met(work) }
        model.updateCategory("ai-chat") { $0.dailyTarget = partway(chat) }
        await shoot(FocusActivityPage(model: model), width: 640, height: 1500, name: "targets-activity-overview", in: directory)
        await shoot(FocusActivityPage(model: model, initialPeriod: .week), width: 640, height: 1500,
                    name: "targets-activity-week", in: directory)

        // The bars: Work's usual day, so some days are over the line and some under.
        let days = (1...7).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: today) }
        let usual = days.map { seconds(in: ActivityCategorizer.workID, on: $0, model: model) }.reduce(0, +) / Double(max(1, days.count))
        model.updateWorkGroup { $0.dailyTarget = met(usual) }
        await shoot(FocusActivityPage(model: model, initialPeriod: .week, initialCategoryFilter: ActivityCategorizer.workID),
                    width: 640, height: 1500, name: "targets-daily-bars-week", in: directory)
        await shoot(FocusActivityPage(model: model, initialPeriod: .month, initialCategoryFilter: ActivityCategorizer.workID),
                    width: 640, height: 1500, name: "targets-daily-bars-month", in: directory)
        // A target taller than any day: the scale grows to hold the line.
        model.updateWorkGroup { $0.dailyTarget = met(usual) * 2 }
        await shoot(FocusActivityPage(model: model, initialPeriod: .week, initialCategoryFilter: ActivityCategorizer.workID),
                    width: 640, height: 1500, name: "targets-daily-bars-tall", in: directory)

        // Settings: a category's page with a target, and the Work group's.
        model.updateWorkGroup { $0.dailyTarget = 4 * 3600 }
        await shoot(FocusCategoryPage(model: model, categoryID: "ai-chat").environment(SettingsRouter()),
                    width: 640, height: 760, name: "targets-category-editor", in: directory)
        await shoot(FocusCategoryPage(model: model, categoryID: ActivityCategorizer.workID, isWork: true).environment(SettingsRouter()),
                    width: 640, height: 600, name: "targets-work-editor", in: directory)
        model.updateWorkGroup { $0.dailyTarget = nil }
        model.updateCategory("ai-chat") { $0.dailyTarget = nil }
    }

    /// The popover's Today piece with a target on Work, part-way.
    static func renderCategoryTargetPopover(model: NidusModel, in directory: URL) async {
        // A break from the run before ends only with a session, then idle.
        model.runHarnessScenario("running")
        model.runHarnessScenario("idle")
        model.goalDraft = ""
        model.seedActivityPreview()
        let work = seconds(in: ActivityCategorizer.workID, on: Date(), model: model)
        model.updateWorkGroup { $0.dailyTarget = partway(work) }
        await shoot(NidusPopover(model: model).background(Color(nsColor: .windowBackgroundColor)), width: 440,
                    name: "targets-popover-partway", in: directory)
        model.updateWorkGroup { $0.dailyTarget = met(work) }
        await shoot(NidusPopover(model: model).background(Color(nsColor: .windowBackgroundColor)), width: 440,
                    name: "targets-popover-met", in: directory)
        model.updateWorkGroup { $0.dailyTarget = nil }
    }
}
