import Combine
import SwiftUI

/// The existing controller clock, observed only by views that display time.
/// It owns no timer and never invalidates settings or historical summaries.
@MainActor
final class FocusClock: ObservableObject {
    @Published private(set) var now = Date()

    func advance(to date: Date) {
        guard now != date else { return }
        now = date
    }
}

/// Keeps second-by-second updates inside a countdown or progress view.
/// The enclosing view still observes the model for session/state changes.
struct FocusClockView<Content: View>: View {
    @ObservedObject private var clock: FocusClock
    private let content: (Date) -> Content

    init(model: NidusModel, @ViewBuilder content: @escaping (Date) -> Content) {
        clock = model.clock
        self.content = content
    }

    var body: some View { content(clock.now) }
}

/// Historical summaries change with their source revision or calendar day,
/// not the countdown. Keeping one value also bounds retained cache memory.
@MainActor
final class HistoryDayCache<Value> {
    private struct Key: Equatable {
        let historyVersion: Int
        let day: Date
        let calendar: Calendar
    }
    private var cached: (key: Key, value: Value)?

    func value(historyVersion: Int, now: Date = Date(), calendar: Calendar = .current,
               build: (Date, Calendar) -> Value) -> Value {
        let key = Key(historyVersion: historyVersion, day: calendar.startOfDay(for: now), calendar: calendar)
        if let cached, cached.key == key { return cached.value }
        let value = build(now, calendar)
        cached = (key, value)
        return value
    }

    func invalidate() { cached = nil }
}
