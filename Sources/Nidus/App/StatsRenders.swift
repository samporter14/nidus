//
//  StatsRenders.swift
//  Nidus
//
//  Demo only: eight weeks of made-up sessions, so the Stats page and
//  Monday's card can be drawn with something on them. The sessions go in the
//  demo's own throwaway folder; nothing here can reach a real history, and
//  nothing here starts a session.
//

import SwiftUI

/// Sessions to look at. The same shape of week every time (the sequence is
/// seeded), counted back from `now`, so a render is repeatable.
enum SampleHistory {
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state ^ (state >> 29)
        }
    }

    static let goals = ["Write the launch post", "Chapter three", "Fix the sync bug", "Review the budget",
                        "Plan the offsite", "Reply to the backlog", "Read the spec"]
    static let names = ["com.tinyspeck.slackmacgap": "Slack", "com.apple.mail": "Mail", "youtube.com": "youtube.com",
                        "x.com": "x.com", "com.apple.dt.Xcode": "Xcode", "com.apple.Safari": "Safari",
                        "com.apple.Notes": "Notes"]

    /// Eight weeks up to and including today. Today and the two days before
    /// always have a session, so there is a streak to show; a few other days
    /// are empty, weekends mostly.
    static func entries(now: Date = Date(), calendar: Calendar = .current, weeks: Int = 8) -> [SessionEntry] {
        var random = Seeded(state: 20_261_005)
        var sessions: [SessionEntry] = []
        let today = calendar.startOfDay(for: now)
        for back in stride(from: weeks * 7 - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let weekend = calendar.isDateInWeekend(day)
            guard back < 3 || Double.random(in: 0..<1, using: &random) < (weekend ? 0.3 : 0.88) else { continue }
            for slot in 0..<Int.random(in: 1...(weekend ? 2 : 4), using: &random) {
                sessions.append(entry(on: day, slot: slot, isToday: back == 0, now: now, calendar: calendar, using: &random))
            }
        }
        return sessions
    }

    private static func entry<R: RandomNumberGenerator>(on day: Date, slot: Int, isToday: Bool, now: Date, calendar: Calendar,
                                                        using random: inout R) -> SessionEntry {
        let lengths: [Double] = [15, 25, 25, 25, 45, 50, 90]
        let minutes: Double = lengths.randomElement(using: &random) ?? 25
        let openEnded = Int.random(in: 0..<12, using: &random) == 0
        let completed = !openEnded && Int.random(in: 0..<4, using: &random) != 0
        let focused = (completed ? minutes : minutes * Double.random(in: 0.4...0.9, using: &random)) * 60
        let hour = 8 + slot * 3 + Int.random(in: 0...1, using: &random)
        var start = calendar.date(byAdding: .hour, value: hour, to: day) ?? day
        // Today's sessions are over by now.
        if isToday { start = min(start, now.addingTimeInterval(-focused - Double(slot) * 4 * 3600 - 300)) }

        let goal = Int.random(in: 0..<10, using: &random) < 7 ? (goals.randomElement(using: &random) ?? "") : ""
        let answered = !goal.isEmpty && Int.random(in: 0..<5, using: &random) != 0
        var blocks: [String: Int] = [:]
        for key in ["youtube.com", "com.tinyspeck.slackmacgap", "x.com", "com.apple.mail"] where Int.random(in: 0..<3, using: &random) == 0 {
            blocks[key] = Int.random(in: 1...4, using: &random)
        }
        // Only apps are quit; a website is only turned away.
        let quits = blocks.filter { $0.key.hasPrefix("com.") }.mapValues { max(1, $0 - 1) }
        let apps = ["com.apple.dt.Xcode", "com.apple.Safari", "com.apple.Notes"].shuffled(using: &random).prefix(2)
        var foreground: [String: TimeInterval] = [:]
        for (index, app) in apps.enumerated() { foreground[app] = focused * (index == 0 ? 0.6 : 0.3) }

        return SessionEntry(start: start, end: start.addingTimeInterval(focused + 120), focused: focused,
                            planned: openEnded ? nil : minutes * 60,
                            outcome: completed ? .completed : .endedEarly, goal: goal, blocks: blocks, quits: quits,
                            foreground: foreground, names: names, finished: answered ? Int.random(in: 0..<3, using: &random) != 0 : nil)
    }
}

extension NidusModel {
    /// The `stats-filled` scenario. Replaces whatever the demo's history held,
    /// so running it twice changes nothing; and does nothing at all outside a
    /// demo or a render, whose history is a throwaway.
    func seedSampleHistory() {
        guard Demo.isActive, let history = controller?.history else { return }
        history.clear()
        SampleHistory.entries().forEach(history.append)
        objectWillChange.send()
    }

    /// The `recap` scenario: last week's card, from the sample sessions.
    func presentSampleRecap() {
        seedSampleHistory()
        let calendar = Calendar.current
        let lastMonday = calendar.date(byAdding: .day, value: -7, to: WeeklyRecap.monday(onOrBefore: Date(), calendar: calendar))
        guard let controller, let lastMonday,
              let recap = WeeklyRecap(sessions: controller.history.sessions, weekStarting: lastMonday, calendar: calendar) else { return }
        presentWeeklyRecapHUD(recap)
    }
}

extension RenderSurfaces {
    /// The pictures that need sessions: the filled Stats page and Monday's
    /// card. They come last, because sessions change the Get started guide
    /// on General, which the others show.
    static func renderStatsExtras(model: NidusModel, settings: SettingsWindowController, host: NidusHost,
                                  in directory: URL) async {
        model.runHarnessScenario("stats-filled")
        await shootSettings(model, settings, page: "stats", title: "Stats", name: "settings-stats-filled", height: 1200, in: directory)

        model.runHarnessScenario("recap")
        if let request = host.hud.lastRequest {
            await shoot(HUDCardView(content: request.content), width: HUDPresenter.width,
                        name: "card-recap", in: directory, padded: true)
        }
        // The demo's folder is thrown away anyway; leave nothing in it.
        model.controller?.clearHistory()
    }
}
