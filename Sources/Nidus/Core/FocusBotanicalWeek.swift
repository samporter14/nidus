import Foundation

/// Seven small marks, earned when a recorded session ends. A manually ended
/// open-ended session counts too; answering the goal's completion question
/// does not change the mark. No history or goal text is retained here.
struct FocusBotanicalWeek: Equatable, Sendable {
    struct Day: Equatable, Sendable, Identifiable {
        var date: Date
        var hasSession: Bool
        var variant: Int
        var id: Date { date }
    }

    let days: [Day]
    var isEmpty: Bool { !days.contains(where: \.hasSession) }

    init(sessions: [SessionEntry], now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let dates = (-6...0).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        guard let first = dates.first else { days = []; return }
        var finishedDays = Set<Date>()
        for session in sessions where session.focused >= SessionEntry.minimumFocus
            && session.end >= first && session.end <= now {
            finishedDays.insert(calendar.startOfDay(for: session.end))
        }
        days = dates.map { date in
            // Based on the calendar date, so a stamp does not change its
            // shape when the seven-day window moves on tomorrow.
            let ordinal = calendar.ordinality(of: .day, in: .era, for: date) ?? calendar.component(.day, from: date)
            return Day(date: date, hasSession: finishedDays.contains(date), variant: ordinal % 3)
        }
    }
}
