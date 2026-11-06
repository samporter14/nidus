//
//  WidgetSnapshot.swift
//  Nidus
//
//  `widget.json` in Nidus's folder: what the desktop widgets and the Control
//  Center controls show (Widget/NidusWidget.swift). The app writes it when
//  the session or the setups change, and at most every 15 minutes for today's
//  activity; the widget, sandboxed, may only read that folder. Nothing in it
//  leaves the Mac. Compiled into both the app and the widget extension.
//

import Foundation

/// Today for the Nidus Today widget: Work, the other categories, which are
/// the ones that distract, and everything else, the same split as the hour
/// grid. Times of day and seconds only: no app or site is named.
struct WidgetToday: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case work, distracting, other }

    struct Band: Codable, Equatable, Sendable {
        /// Minutes since the day began.
        var startMinute: Int
        var endMinute: Int
        var kind: Kind
    }

    /// The most a day draws, which is also what keeps widget.json small.
    static let bandLimit = 24

    /// `YYYY-MM-DD`, as a day's record names itself.
    var day: String
    /// Seconds.
    var work = 0
    var distracting = 0
    var other = 0
    var bands: [Band] = []

    var total: Int { work + distracting + other }

    /// The same key as `ActivityDayLog.key`, which the widget doesn't compile.
    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

struct WidgetSnapshot: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case idle, focusing, paused, onBreak }

    struct Setup: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        var symbol: String
    }

    static let fileName = "widget.json"
    /// How many setups the widget can show.
    static let setupLimit = 4
    /// The Nidus Today widget, reloaded alone when only `today` changed.
    static let todayKind = "local.sam.nidus.today"

    var version = 1
    var state: State = .idle
    var goal: String = ""
    /// When the session or break ends, seconds since 1970. nil when idle,
    /// paused or open-ended.
    var endsAt: Double?
    /// Of a paused session.
    var secondsLeft: Double?
    var strict = false
    var setups: [Setup] = []
    /// nil with nothing counted, and in a file from before this was kept.
    var today: WidgetToday?

    var endDate: Date? { endsAt.map(Date.init(timeIntervalSince1970:)) }

    /// `today`, if it's about the day of `date`: yesterday's numbers are never
    /// shown as today's.
    func today(at date: Date, calendar: Calendar = .current) -> WidgetToday? {
        guard let today, today.total > 0, today.day == WidgetToday.key(for: date, calendar: calendar) else { return nil }
        return today
    }

    /// The links the widget's buttons open: Nidus does the rest, under the
    /// same rules as any nidus:// link (a strict session can't be ended).
    static func startURL(setupID: String) -> URL {
        var components = URLComponents()
        components.scheme = "nidus"
        components.host = "start"
        components.queryItems = [URLQueryItem(name: "preset", value: setupID)]
        return components.url!
    }

    static let endURL = URL(string: "nidus://end")!
    static let popoverURL = URL(string: "nidus://popover")!
}
