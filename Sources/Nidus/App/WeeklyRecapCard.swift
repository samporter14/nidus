//
//  WeeklyRecapCard.swift
//  Nidus
//
//  Monday's card: last week in a line, with a button to the Stats page. It
//  is offered when Nidus launches, when the Mac wakes or unlocks, when the
//  day turns and when Nidus is opened. Those are things the system says on
//  its own; nothing here keeps a timer, because Nidus does nothing between
//  sessions. Once offered, a week is not offered again.
//
//  One gap, plainly: a Mac that stays awake and unlocked from before 9:00
//  shows nothing until the next of those things happens. A timer would close
//  it, and a timer is what the README promises there isn't.
//

import AppKit
import SwiftUI

extension NidusModel.Key {
    /// The `weekID` of the last recap shown.
    static let weeklyRecapShown = "weeklyRecapShown"
}

extension NidusModel {
    static let recapHUDID = "focus.weekly-recap"

    /// Starts listening for the moments a recap may be offered, and asks
    /// once now, for a launch on a Monday. Demos and renders never listen:
    /// they must not touch the settings or history of a real run.
    func startWeeklyRecap() {
        guard !Demo.isActive, recapWatcher == nil else { return }
        let watcher = WeeklyRecapWatcher { [weak self] in self?.offerWeeklyRecap() }
        recapWatcher = watcher
        watcher.start()
    }

    func stopWeeklyRecap() {
        recapWatcher?.stop()
        recapWatcher = nil
        host?.hud.dismiss(id: Self.recapHUDID)
    }

    /// Shows last week's recap if one is due and nothing else is going on:
    /// no session or break, no other card, and history on. A week counts as
    /// shown only once its card is up, so a busy moment loses nothing.
    @discardableResult
    func offerWeeklyRecap(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let host, let controller else { return false }
        let shown: String = preference(Key.weeklyRecapShown, default: "")
        guard let recap = WeeklyRecap.due(sessions: controller.history.sessions, now: now,
                                          shownWeek: shown.isEmpty ? nil : shown,
                                          recording: recordsHistory,
                                          idle: !isActive && !isOnBreak && !host.hud.isShowing,
                                          calendar: calendar),
              presentWeeklyRecapHUD(recap) else { return false }
        setPreference(recap.weekID, Key.weeklyRecapShown)
        return true
    }

    @discardableResult
    func presentWeeklyRecapHUD(_ recap: WeeklyRecap) -> Bool {
        guard let host else { return false }
        let parts = recap.parts
        let title = recap.title
        let request = DropletHUDRequest(
            id: Self.recapHUDID,
            // Long enough to read a line of numbers and reach the button.
            duration: 10,
            priority: .normal,
            accessibilityLabel: recap.spoken,
            isExpanded: true,
            expandedContentHeight: 64
        ) {
            FocusHUDStrip(symbol: "chart.bar.fill", text: FocusFormat.long(recap.focused))
        } expanded: { [weak self] in
            FocusNoticeCard(symbol: "chart.bar.fill", variants: [
                .init(title: Text(verbatim: title), detail: Text(verbatim: parts.joined(separator: " \u{00B7} ")), button: "Stats"),
                // The mark goes before a part of the line does: the numbers
                // are what the card is for.
                .init(title: Text(verbatim: title), detail: Text(verbatim: parts.joined(separator: " \u{00B7} ")),
                      button: "Stats", showsSymbol: false),
                .init(title: Text(verbatim: "Last week"),
                      detail: Text(verbatim: "\(FocusFormat.long(recap.focused)) \u{00B7} \(parts[0])"),
                      button: "Stats", showsSymbol: false),
            ]) {
                self?.openStats()
                self?.host?.hud.dismiss(id: Self.recapHUDID)
            }
        }
        return host.hud.present(request)
    }
}

/// Listens for the system's own moments of "someone is here": launch, wake,
/// unlock, a new day, Nidus coming forward. Each asks the model whether a
/// recap is due; none polls.
@MainActor
final class WeeklyRecapWatcher {
    private let ask: () -> Void
    private var removals: [() -> Void] = []
    private var isLocked = false
    private var isDisplayAsleep = false
    /// A Mac that wakes to its lock screen, or sits awake with its display
    /// off through midnight, has no one looking: the card would come and go
    /// unseen and the week would be spent. The unlock, or the display coming
    /// back, asks instead.
    private var isAway: Bool { isLocked || isDisplayAsleep }

    init(ask: @escaping () -> Void) {
        self.ask = ask
    }

    func start() {
        guard removals.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let center = NotificationCenter.default

        func listen(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (WeeklyRecapWatcher) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }
            removals.append { center.removeObserver(token) }
        }
        listen(distributed, FocusController.screenLockedNotification) { $0.isLocked = true }
        listen(distributed, FocusController.screenUnlockedNotification) { watcher in
            watcher.isLocked = false
            if !watcher.isAway { watcher.ask() }
        }
        listen(workspace, NSWorkspace.screensDidSleepNotification) { $0.isDisplayAsleep = true }
        listen(workspace, NSWorkspace.screensDidWakeNotification) { watcher in
            watcher.isDisplayAsleep = false
            if !watcher.isAway { watcher.ask() }
        }
        listen(workspace, NSWorkspace.didWakeNotification) { watcher in if !watcher.isAway { watcher.ask() } }
        listen(center, .NSCalendarDayChanged) { watcher in if !watcher.isAway { watcher.ask() } }
        // Nidus has no window of its own; it comes forward when the popover
        // or Settings opens, which is someone at the Mac.
        listen(center, NSApplication.didBecomeActiveNotification) { watcher in if !watcher.isAway { watcher.ask() } }
        ask()
    }

    func stop() {
        removals.forEach { $0() }
        removals.removeAll()
    }
}
