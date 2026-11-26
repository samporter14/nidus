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

    /// A stretch of focus sessions today, in minutes since the day began.
    struct Span: Codable, Equatable, Sendable {
        var startMinute: Int
        var endMinute: Int
    }

    /// One of the day's biggest categories, for the large widget. `tint` is
    /// what the app's charts use: 0 or more is a palette slot, -1 the quiet
    /// "other", -2 the Work group.
    struct Category: Codable, Equatable, Sendable {
        var name: String
        var minutes: Int
        var tint: Int
    }

    /// The first category with a daily target, for a progress line. `tint` is
    /// the same as a `Category`'s. Seconds throughout.
    struct Target: Codable, Equatable, Sendable {
        var name: String
        var seconds: Int
        var target: Int
        var tint: Int

        /// The longest a target can be: a day (CategoryTarget.maximum, which
        /// the widget doesn't compile).
        static let limit = 86_400

        /// 0 to 1. Both are compared as the whole minutes the widget shows, so
        /// "4h of 4h" is never short (CategoryTarget.fraction).
        var fraction: Double {
            let goal = Self.shown(target)
            return goal > 0 ? min(1, max(0, Self.shown(seconds) / goal)) : 0
        }

        var isMet: Bool { Self.shown(target) > 0 && Self.shown(seconds) >= Self.shown(target) }

        private static func shown(_ seconds: Int) -> Double {
            let value = Double(max(0, seconds))
            return value < 60 ? value : (value / 60).rounded() * 60
        }

        init(name: String, seconds: Int, target: Int, tint: Int) {
            self.name = name
            self.seconds = max(0, seconds)
            self.target = target
            self.tint = tint
        }

        /// A target that is not a positive length within a day is no target:
        /// the decode fails and `WidgetToday` drops it.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            let seconds = try c.decode(Int.self, forKey: .seconds)
            let target = try c.decode(Int.self, forKey: .target)
            guard target > 0, target <= Self.limit else {
                throw DecodingError.dataCorruptedError(forKey: .target, in: c, debugDescription: "Not a daily target")
            }
            self.seconds = max(0, seconds)
            self.target = target
            tint = (try? c.decodeIfPresent(Int.self, forKey: .tint)) ?? -1
        }
    }

    /// The most a day draws, which is also what keeps widget.json small.
    static let bandLimit = 24
    /// The most focus spans and categories the large widget is given.
    static let spanLimit = 24
    static let topLimit = 3

    /// `YYYY-MM-DD`, as a day's record names itself.
    var day: String
    /// Seconds.
    var work = 0
    var distracting = 0
    var other = 0
    var bands: [Band] = []
    /// When today's focus sessions ran. nil in a file from before this was kept.
    var focus: [Span]?
    /// The day's three biggest categories, biggest first. nil likewise.
    var top: [Category]?
    /// The first category with a daily target. nil with none, and in a file
    /// from before this was kept.
    var target: Target?

    var total: Int { work + distracting + other }

    /// The same key as `ActivityDayLog.key`, which the widget doesn't compile.
    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension WidgetToday {
    /// Tolerant: a field that is missing or malformed falls back to its default
    /// and never takes the rest of the day with it. Only `day` is required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        work = (try? c.decodeIfPresent(Int.self, forKey: .work)) ?? 0
        distracting = (try? c.decodeIfPresent(Int.self, forKey: .distracting)) ?? 0
        other = (try? c.decodeIfPresent(Int.self, forKey: .other)) ?? 0
        bands = (try? c.decodeIfPresent([Band].self, forKey: .bands)) ?? []
        focus = try? c.decodeIfPresent([Span].self, forKey: .focus)
        top = try? c.decodeIfPresent([Category].self, forKey: .top)
        target = try? c.decodeIfPresent(Target.self, forKey: .target)
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

extension WidgetSnapshot {
    /// Tolerant: a malformed `today` is dropped rather than blanking the
    /// session and the setups, which the controls need.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        state = (try? c.decodeIfPresent(State.self, forKey: .state)) ?? .idle
        goal = (try? c.decodeIfPresent(String.self, forKey: .goal)) ?? ""
        endsAt = try? c.decodeIfPresent(Double.self, forKey: .endsAt)
        secondsLeft = try? c.decodeIfPresent(Double.self, forKey: .secondsLeft)
        strict = (try? c.decodeIfPresent(Bool.self, forKey: .strict)) ?? false
        setups = (try? c.decodeIfPresent([Setup].self, forKey: .setups)) ?? []
        today = try? c.decodeIfPresent(WidgetToday.self, forKey: .today)
    }
}
