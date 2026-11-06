//
//  WidgetBridge.swift
//  Nidus
//
//  Keeps `widget.json` (WidgetSnapshot) up to date for the desktop widget and
//  the Control Center controls, and asks WidgetKit to redraw them only when
//  it changed: at a start, a pause, an end, a new setup. The countdown is
//  drawn by the widget itself from the end time, so nothing is written
//  every second.
//
//  Today's activity is worked out away from the main actor, on a save and at
//  most every 15 minutes (WidgetTodayThrottle), and kept here. `publishWidget`
//  runs every second and only reads what's kept.
//

import Foundation
import WidgetKit

extension WidgetSnapshot {
    /// Only the Nidus Today widget has anything new to draw.
    func differsOnlyInToday(from other: WidgetSnapshot?) -> Bool {
        guard var other, other.today != today else { return false }
        other.today = today
        return other == self
    }
}

extension NidusModel {
    @MainActor private static var lastWidget: WidgetSnapshot?

    var widgetSnapshot: WidgetSnapshot {
        var snapshot = WidgetSnapshot()
        snapshot.setups = widgetSetupCache.value(setups: setups)
        snapshot.today = widgetToday
        if let session = engine?.session {
            snapshot.goal = session.plan.goal
            snapshot.strict = session.plan.strict
            switch session.phase {
            case .running(let deadline):
                snapshot.state = .focusing
                snapshot.endsAt = session.plan.duration == nil ? nil : deadline.timeIntervalSince1970.rounded()
            case .paused(let remaining, _):
                snapshot.state = .paused
                snapshot.secondsLeft = session.plan.duration == nil ? nil : remaining.rounded()
            }
        } else if let pending = engine?.breakState {
            snapshot.state = .onBreak
            snapshot.goal = pending.plan.goal
            snapshot.endsAt = pending.endsAt.timeIntervalSince1970.rounded()
        }
        return snapshot
    }

    /// Writes the file and reloads the widgets when anything they show changed.
    func publishWidget(quitting: Bool = false) {
        guard !Demo.isActive, let directory = containerDirectory else { return }
        var snapshot = widgetSnapshot
        // What was counted today stays true after Nidus quits.
        if quitting { snapshot = WidgetSnapshot(setups: snapshot.setups, today: snapshot.today) }
        guard snapshot != Self.lastWidget else { return }
        let onlyToday = snapshot.differsOnlyInToday(from: Self.lastWidget)
        Self.lastWidget = snapshot
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: directory.appendingPathComponent(WidgetSnapshot.fileName), options: .atomic)
        if onlyToday {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.todayKind)
        } else {
            WidgetCenter.shared.reloadAllTimelines()
            ControlCenter.shared.reloadAllControls()
        }
    }

    /// What the last run left, if it's about today, so that launching doesn't
    /// blank the widget until the first summary lands.
    func restoreWidgetToday(now: Date = Date()) {
        guard !Demo.isActive, let directory = containerDirectory,
              let data = try? Data(contentsOf: directory.appendingPathComponent(WidgetSnapshot.fileName)),
              let today = try? JSONDecoder().decode(WidgetSnapshot.self, from: data).today,
              today.day == WidgetToday.key(for: now) else { return }
        widgetToday = today
    }

    /// A save landed. Worked out only when the throttle says so; the latest
    /// call wins, so two saves can't finish out of order.
    func refreshWidgetToday(now: Date = Date()) {
        guard !Demo.isActive, let controller else { return }
        let day = WidgetToday.key(for: now)
        let source = WidgetTodayThrottle.Source(version: controller.historyClears, excluded: controller.activityExcludedApps)
        guard widgetTodayThrottle.isDue(day: day, source: source, now: now) else { return }
        widgetTodayThrottle.source = source
        widgetTodayTask?.cancel()
        widgetTodayTask = Task { [weak self] in
            guard let summary = await self?.activityToday(now: now), !Task.isCancelled, let self else { return }
            let today = summary.total > 0 ? summary : nil
            guard today != widgetToday else { return }
            widgetToday = today
            widgetTodayThrottle.didWrite(day: day, at: now)
            publishWidget()
        }
    }

    /// Today as the views show it, for the widget and the Shortcuts actions.
    /// The record is read here, on the main actor, and split away from it.
    func activityToday(now: Date = Date()) async -> WidgetToday {
        let day = WidgetToday.key(for: now)
        guard let controller else { return WidgetToday(day: day) }
        var log = controller.activityRecorder.today().hiding(controller.activityExcludedApps)
        // Tracking off, the recorder still holds the day it stopped on.
        if log.day != day { log = ActivityDayLog(day: day) }
        let categorizer = activityCategorizer
        return await Task.detached(priority: .utility) {
            ActivityTodaySummary.build(log: log, categorizer: categorizer)
        }.value
    }
}
