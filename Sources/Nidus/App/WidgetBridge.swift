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

import Foundation
import WidgetKit

extension NidusModel {
    @MainActor private static var lastWidget: WidgetSnapshot?

    var widgetSnapshot: WidgetSnapshot {
        var snapshot = WidgetSnapshot()
        snapshot.setups = setups.prefix(WidgetSnapshot.setupLimit).map {
            WidgetSnapshot.Setup(id: $0.id.uuidString, name: $0.name, symbol: $0.symbol)
        }
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
        if quitting { snapshot = WidgetSnapshot(setups: snapshot.setups) }
        guard snapshot != Self.lastWidget else { return }
        Self.lastWidget = snapshot
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: directory.appendingPathComponent(WidgetSnapshot.fileName), options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }
}
